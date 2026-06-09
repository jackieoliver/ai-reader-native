import Foundation

public struct CartesiaSpeechInput: Equatable, Sendable {
  public static let fastestSpeedMultiplier = 1.5

  public var configuration: CartesiaConfiguration
  public var text: String
  public var speedMultiplier: Double
  public var volume: Double

  public init(
    configuration: CartesiaConfiguration,
    text: String,
    speedMultiplier: Double = Self.fastestSpeedMultiplier,
    volume: Double = 1
  ) {
    self.configuration = configuration
    self.text = text
    self.speedMultiplier = speedMultiplier
    self.volume = volume
  }
}

public final class CartesiaSpeechService: @unchecked Sendable {
  private let session: URLSession
  private let endpoint: URL

  public init(
    session: URLSession = .shared,
    endpoint: URL = URL(string: "https://api.cartesia.ai/tts/bytes")!
  ) {
    self.session = session
    self.endpoint = endpoint
  }

  public func synthesize(_ input: CartesiaSpeechInput) async throws -> Data {
    let request = try makeRequest(input)
    let (data, response) = try await session.data(for: request)

    guard let httpResponse = response as? HTTPURLResponse else {
      throw ProviderAPIError.invalidResponse(provider: "Cartesia")
    }

    guard (200...299).contains(httpResponse.statusCode) else {
      throw ProviderAPIError.httpError(
        provider: "Cartesia",
        statusCode: httpResponse.statusCode,
        body: String(data: data, encoding: .utf8) ?? ""
      )
    }

    guard !data.isEmpty else {
      throw ProviderAPIError.emptyResponse(provider: "Cartesia")
    }

    return data
  }

  public func makeRequest(_ input: CartesiaSpeechInput) throws -> URLRequest {
    var request = URLRequest(url: endpoint)
    request.httpMethod = "POST"
    request.setValue("Bearer \(input.configuration.apiKey)", forHTTPHeaderField: "Authorization")
    request.setValue(input.configuration.version, forHTTPHeaderField: "Cartesia-Version")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("audio/wav", forHTTPHeaderField: "Accept")

    let body = CartesiaSpeechRequest(
      modelID: input.configuration.modelID,
      transcript: input.text,
      voice: .init(id: input.configuration.voiceID),
      language: input.configuration.language,
      outputFormat: .wav,
      generationConfig: .init(speed: Self.speedMultiplier(input.speedMultiplier), volume: Self.volumeMultiplier(input.volume))
    )
    request.httpBody = try JSONEncoder().encode(body)
    return request
  }

  fileprivate static func speedMultiplier(_ value: Double) -> Double {
    min(max(value, 0.6), 1.5)
  }

  fileprivate static func volumeMultiplier(_ value: Double) -> Double {
    min(max(value, 0.5), 2.0)
  }
}

public struct CartesiaStreamingSpeechInput: Equatable, Sendable {
  public var configuration: CartesiaConfiguration
  public var text: String
  public var speedMultiplier: Double
  public var volume: Double
  public var sampleRate: Int
  public var maxBufferDelayMS: Int

  public init(
    configuration: CartesiaConfiguration,
    text: String,
    speedMultiplier: Double = CartesiaSpeechInput.fastestSpeedMultiplier,
    volume: Double = 1,
    sampleRate: Int = 44_100,
    maxBufferDelayMS: Int = 0
  ) {
    self.configuration = configuration
    self.text = text
    self.speedMultiplier = speedMultiplier
    self.volume = volume
    self.sampleRate = sampleRate
    self.maxBufferDelayMS = maxBufferDelayMS
  }
}

public struct CartesiaStreamingAudioChunk: Equatable, Sendable {
  public var data: Data
  public var stepTimeMS: Int?
  public var contextID: String?

  public init(data: Data, stepTimeMS: Int?, contextID: String?) {
    self.data = data
    self.stepTimeMS = stepTimeMS
    self.contextID = contextID
  }
}

public enum CartesiaStreamingSpeechEvent: Equatable, Sendable {
  case connected(reused: Bool)
  case requestSent(contextID: String)
  case audioChunk(CartesiaStreamingAudioChunk)
  case done(contextID: String?)
}

public enum CartesiaWebSocketSpeechError: LocalizedError, Equatable, Sendable {
  case invalidMessage(String)
  case invalidAudioChunk
  case providerError(title: String, message: String, statusCode: Int?)
  case connectionValidationTimedOut

  public var errorDescription: String? {
    switch self {
    case .invalidMessage(let reason):
      return "Cartesia sent an invalid WebSocket message: \(reason)"
    case .invalidAudioChunk:
      return "Cartesia sent an invalid audio chunk."
    case .providerError(let title, let message, let statusCode):
      let prefix = statusCode.map { "Cartesia WebSocket error \($0)" } ?? "Cartesia WebSocket error"
      return "\(prefix): \(title). \(message)"
    case .connectionValidationTimedOut:
      return "Cartesia WebSocket validation timed out."
    }
  }
}

public actor CartesiaWebSocketSpeechService {
  public static let defaultEndpoint = URL(string: "wss://api.cartesia.ai/tts/websocket")!
  private let session: URLSession
  private let endpoint: URL
  private var webSocketTask: URLSessionWebSocketTask?
  private var connectionID: CartesiaWebSocketConnectionID?
  private var lastSocketValidationNanoseconds: UInt64?
  private let reuseValidationIntervalNanoseconds: UInt64 = 3_000_000_000
  private let reuseValidationPingTimeout: TimeInterval = 0.5
  private let warmUpPingTimeout: TimeInterval = 1.0

  public init(
    session: URLSession = .shared,
    endpoint: URL = CartesiaWebSocketSpeechService.defaultEndpoint
  ) {
    self.session = session
    self.endpoint = endpoint
  }

  public func warmUp(configuration: CartesiaConfiguration) async throws {
    let (task, _) = try await ensureWebSocket(configuration: configuration)
    try Task.checkCancellation()
    try await sendPing(on: task, timeout: warmUpPingTimeout)
    lastSocketValidationNanoseconds = DispatchTime.now().uptimeNanoseconds
  }

  public nonisolated func events(
    for input: CartesiaStreamingSpeechInput
  ) -> AsyncThrowingStream<CartesiaStreamingSpeechEvent, Error> {
    AsyncThrowingStream { continuation in
      let task = Task {
        do {
          try await self.generate(input) { event in
            continuation.yield(event)
          }
          continuation.finish()
        } catch {
          continuation.finish(throwing: error)
        }
      }

      continuation.onTermination = { _ in
        task.cancel()
      }
    }
  }

  public nonisolated func events(
    for input: CartesiaStreamingSpeechInput,
    textSegments: AsyncThrowingStream<String, Error>
  ) -> AsyncThrowingStream<CartesiaStreamingSpeechEvent, Error> {
    AsyncThrowingStream { continuation in
      let task = Task {
        do {
          try await self.generate(input, textSegments: textSegments) { event in
            continuation.yield(event)
          }
          continuation.finish()
        } catch {
          continuation.finish(throwing: error)
        }
      }

      continuation.onTermination = { _ in
        task.cancel()
      }
    }
  }

  public static func makeRequest(
    configuration: CartesiaConfiguration,
    endpoint: URL = CartesiaWebSocketSpeechService.defaultEndpoint
  ) throws -> URLRequest {
    var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)
    var queryItems = components?.queryItems ?? []
    queryItems.removeAll { $0.name == "cartesia_version" }
    queryItems.append(URLQueryItem(name: "cartesia_version", value: configuration.version))
    components?.queryItems = queryItems

    guard let url = components?.url else {
      throw ProviderAPIError.invalidResponse(provider: "Cartesia")
    }

    var request = URLRequest(url: url)
    request.setValue(configuration.apiKey, forHTTPHeaderField: "X-API-Key")
    request.setValue(configuration.version, forHTTPHeaderField: "Cartesia-Version")
    return request
  }

  public static func makeGenerationPayload(
    _ input: CartesiaStreamingSpeechInput,
    contextID: String,
    transcript: String? = nil,
    continueGeneration: Bool = false
  ) throws -> Data {
    let body = CartesiaWebSocketGenerationRequest(
      modelID: input.configuration.modelID,
      transcript: transcript ?? input.text,
      voice: .init(id: input.configuration.voiceID),
      language: input.configuration.language,
      contextID: contextID,
      outputFormat: .rawPCMFloat32(sampleRate: input.sampleRate),
      generationConfig: .init(
        speed: CartesiaSpeechService.speedMultiplier(input.speedMultiplier),
        volume: CartesiaSpeechService.volumeMultiplier(input.volume)
      ),
      maxBufferDelayMS: input.maxBufferDelayMS,
      continueGeneration: continueGeneration
    )
    return try JSONEncoder().encode(body)
  }

  private func generate(
    _ input: CartesiaStreamingSpeechInput,
    yieldEvent: @escaping @Sendable (CartesiaStreamingSpeechEvent) async -> Void
  ) async throws {
    let (task, reused) = try await ensureWebSocket(configuration: input.configuration)
    let contextID = UUID().uuidString

    do {
      try Task.checkCancellation()
      await yieldEvent(.connected(reused: reused))

      let payload = try Self.makeGenerationPayload(input, contextID: contextID)
      guard let payloadString = String(data: payload, encoding: .utf8) else {
        throw CartesiaWebSocketSpeechError.invalidMessage("Could not encode generation request as UTF-8.")
      }

      try await task.send(.string(payloadString))
      await yieldEvent(.requestSent(contextID: contextID))

      while true {
        try Task.checkCancellation()
        let response = try await receiveResponse(from: task)

        if response.type == "error" {
          throw CartesiaWebSocketSpeechError.providerError(
            title: response.title ?? "Generation failed",
            message: response.message ?? response.errorCode ?? "Unknown error",
            statusCode: response.statusCode
          )
        }

        if response.type == "chunk", let encodedAudio = response.data {
          guard let audio = Data(base64Encoded: encodedAudio) else {
            throw CartesiaWebSocketSpeechError.invalidAudioChunk
          }
          await yieldEvent(
            .audioChunk(
              CartesiaStreamingAudioChunk(
                data: audio,
                stepTimeMS: response.stepTime,
                contextID: response.contextID
              )
            )
          )
        }

        if response.done == true || response.type == "done" {
          await yieldEvent(.done(contextID: response.contextID))
          return
        }
      }
    } catch {
      if Task.isCancelled {
        try? await cancel(contextID: contextID, on: task)
      }
      closeWebSocket()
      throw error
    }
  }

  private func generate(
    _ input: CartesiaStreamingSpeechInput,
    textSegments: AsyncThrowingStream<String, Error>,
    yieldEvent: @escaping @Sendable (CartesiaStreamingSpeechEvent) async -> Void
  ) async throws {
    let (task, reused) = try await ensureWebSocket(configuration: input.configuration)
    let contextID = UUID().uuidString

    let senderTask = Task {
      var sentAnySegment = false
      for try await segment in textSegments {
        try Task.checkCancellation()
        guard !segment.isEmpty else { continue }
        let payload = try Self.makeGenerationPayload(
          input,
          contextID: contextID,
          transcript: segment,
          continueGeneration: true
        )
        guard let payloadString = String(data: payload, encoding: .utf8) else {
          throw CartesiaWebSocketSpeechError.invalidMessage("Could not encode continuation request as UTF-8.")
        }
        try await task.send(.string(payloadString))
        if !sentAnySegment {
          sentAnySegment = true
          await yieldEvent(.requestSent(contextID: contextID))
        }
      }

      let payload = try Self.makeGenerationPayload(
        input,
        contextID: contextID,
        transcript: "",
        continueGeneration: false
      )
      guard let payloadString = String(data: payload, encoding: .utf8) else {
        throw CartesiaWebSocketSpeechError.invalidMessage("Could not encode final continuation request as UTF-8.")
      }
      try await task.send(.string(payloadString))
      if !sentAnySegment {
        await yieldEvent(.requestSent(contextID: contextID))
      }
    }

    do {
      try Task.checkCancellation()
      await yieldEvent(.connected(reused: reused))

      while true {
        try Task.checkCancellation()
        let response = try await receiveResponse(from: task)

        if response.type == "error" {
          throw CartesiaWebSocketSpeechError.providerError(
            title: response.title ?? "Generation failed",
            message: response.message ?? response.errorCode ?? "Unknown error",
            statusCode: response.statusCode
          )
        }

        if response.type == "chunk", let encodedAudio = response.data {
          guard let audio = Data(base64Encoded: encodedAudio) else {
            throw CartesiaWebSocketSpeechError.invalidAudioChunk
          }
          await yieldEvent(
            .audioChunk(
              CartesiaStreamingAudioChunk(
                data: audio,
                stepTimeMS: response.stepTime,
                contextID: response.contextID
              )
            )
          )
        }

        if response.done == true || response.type == "done" {
          try await senderTask.value
          await yieldEvent(.done(contextID: response.contextID))
          return
        }
      }
    } catch {
      senderTask.cancel()
      if Task.isCancelled {
        try? await cancel(contextID: contextID, on: task)
      }
      closeWebSocket()
      throw error
    }
  }

  private func ensureWebSocket(configuration: CartesiaConfiguration) async throws -> (URLSessionWebSocketTask, Bool) {
    let nextConnectionID = CartesiaWebSocketConnectionID(
      apiKey: configuration.apiKey,
      version: configuration.version
    )

    if let webSocketTask,
      connectionID == nextConnectionID,
      webSocketTask.state == .running
    {
      let now = DispatchTime.now().uptimeNanoseconds
      if let lastSocketValidationNanoseconds,
        now >= lastSocketValidationNanoseconds,
        now - lastSocketValidationNanoseconds < reuseValidationIntervalNanoseconds
      {
        return (webSocketTask, true)
      }

      do {
        try await sendPing(on: webSocketTask, timeout: reuseValidationPingTimeout)
        lastSocketValidationNanoseconds = DispatchTime.now().uptimeNanoseconds
        return (webSocketTask, true)
      } catch {
        closeWebSocket()
      }
    }

    closeWebSocket()

    let request = try Self.makeRequest(configuration: configuration, endpoint: endpoint)
    let task = session.webSocketTask(with: request)
    task.maximumMessageSize = 16 * 1024 * 1024
    task.resume()

    webSocketTask = task
    connectionID = nextConnectionID
    lastSocketValidationNanoseconds = DispatchTime.now().uptimeNanoseconds
    return (task, false)
  }

  private func receiveResponse(from task: URLSessionWebSocketTask) async throws -> CartesiaWebSocketResponse {
    let message = try await task.receive()
    let data: Data

    switch message {
    case .string(let text):
      guard let messageData = text.data(using: .utf8) else {
        throw CartesiaWebSocketSpeechError.invalidMessage("Text response was not UTF-8.")
      }
      data = messageData
    case .data(let messageData):
      data = messageData
    @unknown default:
      throw CartesiaWebSocketSpeechError.invalidMessage("Unknown URLSession WebSocket message kind.")
    }

    do {
      return try CartesiaWebSocketResponse.decode(from: data)
    } catch {
      let preview = String(data: data.prefix(500), encoding: .utf8) ?? "<binary \(data.count) bytes>"
      throw CartesiaWebSocketSpeechError.invalidMessage("\(error.localizedDescription). Preview: \(preview)")
    }
  }

  private func cancel(contextID: String, on task: URLSessionWebSocketTask) async throws {
    let payload = try JSONEncoder().encode(CartesiaWebSocketCancelRequest(contextID: contextID))
    guard let payloadString = String(data: payload, encoding: .utf8) else {
      throw CartesiaWebSocketSpeechError.invalidMessage("Could not encode cancel request as UTF-8.")
    }
    try await task.send(.string(payloadString))
  }

  private func sendPing(on task: URLSessionWebSocketTask, timeout: TimeInterval? = nil) async throws {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      let box = PingContinuationBox(continuation)
      task.sendPing { error in
        if let error {
          box.resume(throwing: error)
        } else {
          box.resume()
        }
      }

      if let timeout {
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
          box.resume(throwing: CartesiaWebSocketSpeechError.connectionValidationTimedOut)
        }
      }
    }
  }

  private func closeWebSocket() {
    webSocketTask?.cancel(with: .goingAway, reason: nil)
    webSocketTask = nil
    connectionID = nil
    lastSocketValidationNanoseconds = nil
  }
}

private final class PingContinuationBox: @unchecked Sendable {
  private let lock = NSLock()
  private var continuation: CheckedContinuation<Void, Error>?

  init(_ continuation: CheckedContinuation<Void, Error>) {
    self.continuation = continuation
  }

  func resume() {
    lock.lock()
    let continuation = self.continuation
    self.continuation = nil
    lock.unlock()
    continuation?.resume()
  }

  func resume(throwing error: Error) {
    lock.lock()
    let continuation = self.continuation
    self.continuation = nil
    lock.unlock()
    continuation?.resume(throwing: error)
  }
}

private struct CartesiaSpeechRequest: Encodable {
  var modelID: String
  var transcript: String
  var voice: CartesiaVoiceRequest
  var language: String
  var outputFormat: CartesiaOutputFormat
  var generationConfig: CartesiaGenerationConfig

  enum CodingKeys: String, CodingKey {
    case modelID = "model_id"
    case transcript
    case voice
    case language
    case outputFormat = "output_format"
    case generationConfig = "generation_config"
  }
}

private struct CartesiaVoiceRequest: Encodable {
  var id: String
}

private struct CartesiaOutputFormat: Encodable {
  var container: String
  var encoding: String
  var sampleRate: Int

  static let wav = CartesiaOutputFormat(container: "wav", encoding: "pcm_f32le", sampleRate: 44_100)
  static func rawPCMFloat32(sampleRate: Int) -> CartesiaOutputFormat {
    CartesiaOutputFormat(container: "raw", encoding: "pcm_f32le", sampleRate: sampleRate)
  }

  enum CodingKeys: String, CodingKey {
    case container
    case encoding
    case sampleRate = "sample_rate"
  }
}

private struct CartesiaGenerationConfig: Encodable {
  var speed: Double
  var volume: Double
}

private struct CartesiaWebSocketConnectionID: Equatable {
  var apiKey: String
  var version: String
}

private struct CartesiaWebSocketGenerationRequest: Encodable {
  var modelID: String
  var transcript: String
  var voice: CartesiaWebSocketVoiceRequest
  var language: String
  var contextID: String
  var outputFormat: CartesiaOutputFormat
  var generationConfig: CartesiaGenerationConfig
  var maxBufferDelayMS: Int
  var continueGeneration: Bool

  enum CodingKeys: String, CodingKey {
    case modelID = "model_id"
    case transcript
    case voice
    case language
    case contextID = "context_id"
    case outputFormat = "output_format"
    case generationConfig = "generation_config"
    case maxBufferDelayMS = "max_buffer_delay_ms"
    case continueGeneration = "continue"
  }
}

private struct CartesiaWebSocketVoiceRequest: Encodable {
  var mode = "id"
  var id: String
}

private struct CartesiaWebSocketResponse {
  var type: String
  var data: String?
  var done: Bool?
  var statusCode: Int?
  var stepTime: Int?
  var contextID: String?
  var title: String?
  var message: String?
  var errorCode: String?

  static func decode(from data: Data) throws -> CartesiaWebSocketResponse {
    let decoded = try JSONSerialization.jsonObject(with: data)
    guard let object = decoded as? [String: Any] else {
      throw CartesiaWebSocketResponseDecodeError.notObject
    }
    guard let type = stringValue(object["type"]) else {
      throw CartesiaWebSocketResponseDecodeError.missingType
    }

    return CartesiaWebSocketResponse(
      type: type,
      data: stringValue(object["data"]),
      done: boolValue(object["done"]),
      statusCode: intValue(object["status_code"]),
      stepTime: intValue(object["step_time"]),
      contextID: stringValue(object["context_id"]),
      title: stringValue(object["title"]),
      message: stringValue(object["message"]),
      errorCode: stringValue(object["error_code"])
    )
  }

  private static func stringValue(_ value: Any?) -> String? {
    switch value {
    case let value as String:
      return value
    case let value as NSNumber:
      return value.stringValue
    default:
      return nil
    }
  }

  private static func intValue(_ value: Any?) -> Int? {
    switch value {
    case let value as Int:
      return value
    case let value as Double:
      return Int(value.rounded())
    case let value as NSNumber:
      return value.intValue
    case let value as String:
      guard let number = Double(value), number.isFinite else {
        return nil
      }
      return Int(number.rounded())
    default:
      return nil
    }
  }

  private static func boolValue(_ value: Any?) -> Bool? {
    switch value {
    case let value as Bool:
      return value
    case let value as NSNumber:
      return value.boolValue
    case let value as String:
      if ["true", "1", "yes"].contains(value.lowercased()) {
        return true
      }
      if ["false", "0", "no"].contains(value.lowercased()) {
        return false
      }
      return nil
    default:
      return nil
    }
  }
}

private enum CartesiaWebSocketResponseDecodeError: LocalizedError {
  case notObject
  case missingType

  var errorDescription: String? {
    switch self {
    case .notObject:
      return "response is not a JSON object"
    case .missingType:
      return "response is missing a type field"
    }
  }
}

private struct CartesiaWebSocketCancelRequest: Encodable {
  var contextID: String
  var cancel = true

  enum CodingKeys: String, CodingKey {
    case contextID = "context_id"
    case cancel
  }
}
