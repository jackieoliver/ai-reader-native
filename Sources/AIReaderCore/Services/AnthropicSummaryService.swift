import Foundation

public struct AnthropicSummaryInput: Equatable, Sendable {
  public var configuration: AnthropicConfiguration
  public var prompt: String
  public var sourceText: String

  public init(configuration: AnthropicConfiguration, prompt: String, sourceText: String) {
    self.configuration = configuration
    self.prompt = prompt
    self.sourceText = sourceText
  }
}

public struct AnthropicChatInput: Equatable, Sendable {
  public var configuration: AnthropicConfiguration
  public var systemPrompt: String
  public var messages: [AnthropicChatMessage]

  public init(configuration: AnthropicConfiguration, systemPrompt: String, messages: [AnthropicChatMessage]) {
    self.configuration = configuration
    self.systemPrompt = systemPrompt
    self.messages = messages
  }
}

public struct AnthropicChatMessage: Equatable, Sendable {
  public var role: AnthropicChatRole
  public var content: String

  public init(role: AnthropicChatRole, content: String) {
    self.role = role
    self.content = content
  }
}

public enum AnthropicChatRole: String, Equatable, Sendable {
  case user
  case assistant
}

public enum AnthropicStreamingEvent: Equatable, Sendable {
  case responseStarted
  case textDelta(String)
  case messageStop
}

public final class AnthropicSummaryService: @unchecked Sendable {
  private let session: URLSession
  private let endpoint: URL

  public init(
    session: URLSession = .shared,
    endpoint: URL = URL(string: "https://api.anthropic.com/v1/messages")!
  ) {
    self.session = session
    self.endpoint = endpoint
  }

  public func summarize(_ input: AnthropicSummaryInput) async throws -> String {
    let request = try makeRequest(input)
    return try await send(request)
  }

  public func chat(_ input: AnthropicChatInput) async throws -> String {
    let request = try makeRequest(input)
    return try await send(request)
  }

  public func streamSummary(_ input: AnthropicSummaryInput) -> AsyncThrowingStream<AnthropicStreamingEvent, Error> {
    stream(
      AnthropicChatInput(
        configuration: input.configuration,
        systemPrompt: input.prompt,
        messages: [
          AnthropicChatMessage(role: .user, content: input.sourceText)
        ]
      )
    )
  }

  public func stream(_ input: AnthropicChatInput) -> AsyncThrowingStream<AnthropicStreamingEvent, Error> {
    AsyncThrowingStream { continuation in
      let task = Task {
        do {
          let request = try makeRequest(input, stream: true)
          try await sendStreaming(request, continuation: continuation)
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

  private func send(_ request: URLRequest) async throws -> String {
    let (data, response) = try await session.data(for: request)

    guard let httpResponse = response as? HTTPURLResponse else {
      throw ProviderAPIError.invalidResponse(provider: "Anthropic")
    }

    guard (200...299).contains(httpResponse.statusCode) else {
      throw ProviderAPIError.httpError(
        provider: "Anthropic",
        statusCode: httpResponse.statusCode,
        body: String(data: data, encoding: .utf8) ?? ""
      )
    }

    let decoded = try JSONDecoder().decode(AnthropicMessageResponse.self, from: data)
    let summary = decoded.content
      .compactMap(\.text)
      .joined(separator: "\n")
      .trimmingCharacters(in: .whitespacesAndNewlines)

    guard !summary.isEmpty else {
      throw ProviderAPIError.emptyResponse(provider: "Anthropic")
    }

    return summary
  }

  public func makeRequest(_ input: AnthropicSummaryInput) throws -> URLRequest {
    try makeRequest(
      AnthropicChatInput(
        configuration: input.configuration,
        systemPrompt: input.prompt,
        messages: [
          AnthropicChatMessage(role: .user, content: input.sourceText)
        ]
      )
    )
  }

  public func makeRequest(_ input: AnthropicChatInput, stream: Bool = false) throws -> URLRequest {
    var request = URLRequest(url: endpoint)
    request.httpMethod = "POST"
    request.setValue(input.configuration.apiKey, forHTTPHeaderField: "x-api-key")
    request.setValue(input.configuration.version, forHTTPHeaderField: "anthropic-version")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")

    let body = AnthropicMessageRequest(
      model: input.configuration.modelID,
      maxTokens: input.configuration.maxTokens,
      system: input.systemPrompt,
      messages: input.messages.map { .init(role: $0.role.rawValue, content: $0.content) },
      stream: stream ? true : nil
    )
    request.httpBody = try JSONEncoder().encode(body)
    return request
  }

  private func sendStreaming(
    _ request: URLRequest,
    continuation: AsyncThrowingStream<AnthropicStreamingEvent, Error>.Continuation
  ) async throws {
    let (bytes, response) = try await session.bytes(for: request)

    guard let httpResponse = response as? HTTPURLResponse else {
      throw ProviderAPIError.invalidResponse(provider: "Anthropic")
    }

    guard (200...299).contains(httpResponse.statusCode) else {
      var body = ""
      for try await line in bytes.lines {
        body += line
      }
      throw ProviderAPIError.httpError(
        provider: "Anthropic",
        statusCode: httpResponse.statusCode,
        body: body
      )
    }

    continuation.yield(.responseStarted)
    var yieldedText = false

    try await withTaskCancellationHandler {
      for try await line in bytes.lines {
        try Task.checkCancellation()
        guard line.hasPrefix("data: ") else {
          continue
        }

        let payload = String(line.dropFirst("data: ".count))
        if payload == "[DONE]" {
          break
        }

        guard let data = payload.data(using: .utf8) else {
          continue
        }

        let event = try JSONDecoder().decode(AnthropicStreamEnvelope.self, from: data)
        if event.type == "error" {
          throw ProviderAPIError.httpError(
            provider: "Anthropic",
            statusCode: 0,
            body: event.error?.message ?? "Streaming error."
          )
        }
        if event.type == "content_block_delta", let text = event.delta?.text, !text.isEmpty {
          yieldedText = true
          continuation.yield(.textDelta(text))
        }
        if event.type == "message_stop" {
          continuation.yield(.messageStop)
          break
        }
      }
    } onCancel: {
      bytes.task.cancel()
    }

    guard yieldedText else {
      throw ProviderAPIError.emptyResponse(provider: "Anthropic")
    }
  }
}

private struct AnthropicMessageRequest: Encodable {
  var model: String
  var maxTokens: Int
  var system: String
  var messages: [AnthropicRequestMessage]
  var stream: Bool?

  enum CodingKeys: String, CodingKey {
    case model
    case maxTokens = "max_tokens"
    case system
    case messages
    case stream
  }
}

private struct AnthropicRequestMessage: Encodable {
  var role: String
  var content: String
}

private struct AnthropicMessageResponse: Decodable {
  var content: [AnthropicContentBlock]
}

private struct AnthropicContentBlock: Decodable {
  var type: String
  var text: String?
}

private struct AnthropicStreamEnvelope: Decodable {
  var type: String
  var delta: AnthropicStreamDelta?
  var error: AnthropicStreamError?
}

private struct AnthropicStreamDelta: Decodable {
  var type: String?
  var text: String?
}

private struct AnthropicStreamError: Decodable {
  var type: String?
  var message: String?
}
