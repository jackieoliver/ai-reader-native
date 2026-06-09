import AIReaderCore
import XCTest

final class ProviderRequestTests: XCTestCase {
  func testAnthropicRequestMatchesMessagesAPIShape() throws {
    let config = AnthropicConfiguration(
      apiKey: "anthropic-key",
      modelID: "claude-sonnet-4-6",
      version: "2023-06-01",
      maxTokens: 123
    )
    let service = AnthropicSummaryService(endpoint: URL(string: "https://example.com/messages")!)

    let request = try service.makeRequest(
      AnthropicSummaryInput(configuration: config, prompt: "summarize", sourceText: "source text")
    )

    XCTAssertEqual(request.httpMethod, "POST")
    XCTAssertEqual(request.value(forHTTPHeaderField: "x-api-key"), "anthropic-key")
    XCTAssertEqual(request.value(forHTTPHeaderField: "anthropic-version"), "2023-06-01")

    let body = try jsonBody(from: request)
    XCTAssertEqual(body["model"] as? String, "claude-sonnet-4-6")
    XCTAssertEqual(body["max_tokens"] as? Int, 123)
    XCTAssertEqual(body["system"] as? String, "summarize")

    let messages = try XCTUnwrap(body["messages"] as? [[String: Any]])
    XCTAssertEqual(messages.first?["role"] as? String, "user")
    XCTAssertEqual(messages.first?["content"] as? String, "source text")
  }

  func testAnthropicChatRequestKeepsSummaryAsAssistantContext() throws {
    let config = AnthropicConfiguration(
      apiKey: "anthropic-key",
      modelID: "claude-sonnet-4-6",
      version: "2023-06-01",
      maxTokens: 123
    )
    let service = AnthropicSummaryService(endpoint: URL(string: "https://example.com/messages")!)

    let request = try service.makeRequest(
      AnthropicChatInput(
        configuration: config,
        systemPrompt: "chat with the summary",
        messages: [
          AnthropicChatMessage(role: .user, content: "summary context"),
          AnthropicChatMessage(role: .assistant, content: "summary response"),
          AnthropicChatMessage(role: .user, content: "question"),
        ]
      )
    )

    let body = try jsonBody(from: request)
    XCTAssertEqual(body["system"] as? String, "chat with the summary")

    let messages = try XCTUnwrap(body["messages"] as? [[String: Any]])
    XCTAssertEqual(messages.map { $0["role"] as? String }, ["user", "assistant", "user"])
    XCTAssertEqual(messages.map { $0["content"] as? String }, ["summary context", "summary response", "question"])
  }

  func testAnthropicStreamingRequestSetsStreamFlag() throws {
    let config = AnthropicConfiguration(
      apiKey: "anthropic-key",
      modelID: "claude-opus-4-6",
      version: "2023-06-01",
      maxTokens: 123
    )
    let service = AnthropicSummaryService(endpoint: URL(string: "https://example.com/messages")!)

    let request = try service.makeRequest(
      AnthropicChatInput(
        configuration: config,
        systemPrompt: "stream summary",
        messages: [AnthropicChatMessage(role: .user, content: "source text")]
      ),
      stream: true
    )

    let body = try jsonBody(from: request)
    XCTAssertEqual(body["model"] as? String, "claude-opus-4-6")
    XCTAssertEqual(body["stream"] as? Bool, true)
  }

  func testCartesiaRequestMatchesBytesAPIShape() throws {
    let config = CartesiaConfiguration(
      apiKey: "cartesia-key",
      modelID: "sonic-3",
      voiceID: "voice-id",
      language: "en",
      version: "2026-03-01"
    )
    let service = CartesiaSpeechService(endpoint: URL(string: "https://example.com/tts/bytes")!)

    let request = try service.makeRequest(
      CartesiaSpeechInput(configuration: config, text: "read me", speedMultiplier: 2, volume: 3)
    )

    XCTAssertEqual(request.httpMethod, "POST")
    XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer cartesia-key")
    XCTAssertEqual(request.value(forHTTPHeaderField: "Cartesia-Version"), "2026-03-01")
    XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "audio/wav")

    let body = try jsonBody(from: request)
    XCTAssertEqual(body["model_id"] as? String, "sonic-3")
    XCTAssertEqual(body["transcript"] as? String, "read me")
    XCTAssertEqual(body["language"] as? String, "en")

    let voice = try XCTUnwrap(body["voice"] as? [String: Any])
    XCTAssertEqual(voice["id"] as? String, "voice-id")

    let output = try XCTUnwrap(body["output_format"] as? [String: Any])
    XCTAssertEqual(output["container"] as? String, "wav")
    XCTAssertEqual(output["encoding"] as? String, "pcm_f32le")
    XCTAssertEqual(output["sample_rate"] as? Int, 44_100)

    let generationConfig = try XCTUnwrap(body["generation_config"] as? [String: Any])
    XCTAssertEqual(generationConfig["speed"] as? Double, 1.5)
    XCTAssertEqual(generationConfig["volume"] as? Double, 2.0)
  }

  func testCartesiaVoiceListRequestUsesVoiceFilters() throws {
    let service = CartesiaVoiceService(endpoint: URL(string: "https://example.com/voices")!)

    let request = try service.makeRequest(
      CartesiaVoiceListInput(
        apiKey: "cartesia-key",
        language: "en",
        gender: "feminine",
        query: "guide",
        limit: 250
      )
    )

    XCTAssertEqual(request.httpMethod, "GET")
    XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer cartesia-key")
    XCTAssertEqual(request.value(forHTTPHeaderField: "Cartesia-Version"), "2026-03-01")

    let components = try XCTUnwrap(URLComponents(url: request.url!, resolvingAgainstBaseURL: false))
    let query = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
    XCTAssertEqual(query["limit"], "100")
    XCTAssertEqual(query["language"], "en")
    XCTAssertEqual(query["gender"], "feminine")
    XCTAssertEqual(query["q"], "guide")
  }

  func testCartesiaWebSocketRequestUsesRealtimeAuthAndVersion() throws {
    let config = CartesiaConfiguration(
      apiKey: "cartesia-key",
      modelID: "sonic-3",
      voiceID: "voice-id",
      language: "en",
      version: "2026-03-01"
    )

    let request = try CartesiaWebSocketSpeechService.makeRequest(
      configuration: config,
      endpoint: URL(string: "wss://example.com/tts/websocket?keep=1")!
    )

    XCTAssertEqual(request.value(forHTTPHeaderField: "X-API-Key"), "cartesia-key")
    XCTAssertEqual(request.value(forHTTPHeaderField: "Cartesia-Version"), "2026-03-01")

    let components = try XCTUnwrap(URLComponents(url: request.url!, resolvingAgainstBaseURL: false))
    let query = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
    XCTAssertEqual(components.scheme, "wss")
    XCTAssertEqual(query["keep"], "1")
    XCTAssertEqual(query["cartesia_version"], "2026-03-01")
  }

  func testCartesiaWebSocketGenerationPayloadUsesRawPCMChunks() throws {
    let config = CartesiaConfiguration(
      apiKey: "cartesia-key",
      modelID: "sonic-3",
      voiceID: "voice-id",
      language: "en",
      version: "2026-03-01"
    )

    let data = try CartesiaWebSocketSpeechService.makeGenerationPayload(
      CartesiaStreamingSpeechInput(
        configuration: config,
        text: "stream me",
        speedMultiplier: 2,
        volume: 0.25,
        sampleRate: 24_000,
        maxBufferDelayMS: 0
      ),
      contextID: "ctx-1"
    )

    let body = try jsonBody(from: data)
    XCTAssertEqual(body["model_id"] as? String, "sonic-3")
    XCTAssertEqual(body["transcript"] as? String, "stream me")
    XCTAssertEqual(body["language"] as? String, "en")
    XCTAssertEqual(body["context_id"] as? String, "ctx-1")
    XCTAssertEqual(body["max_buffer_delay_ms"] as? Int, 0)
    XCTAssertEqual(body["continue"] as? Bool, false)

    let voice = try XCTUnwrap(body["voice"] as? [String: Any])
    XCTAssertEqual(voice["mode"] as? String, "id")
    XCTAssertEqual(voice["id"] as? String, "voice-id")

    let output = try XCTUnwrap(body["output_format"] as? [String: Any])
    XCTAssertEqual(output["container"] as? String, "raw")
    XCTAssertEqual(output["encoding"] as? String, "pcm_f32le")
    XCTAssertEqual(output["sample_rate"] as? Int, 24_000)

    let generationConfig = try XCTUnwrap(body["generation_config"] as? [String: Any])
    XCTAssertEqual(generationConfig["speed"] as? Double, 1.5)
    XCTAssertEqual(generationConfig["volume"] as? Double, 0.5)
  }

  func testCartesiaWebSocketContinuationPayloadKeepsContextOpen() throws {
    let config = CartesiaConfiguration(
      apiKey: "cartesia-key",
      modelID: "sonic-3",
      voiceID: "voice-id",
      language: "en",
      version: "2026-03-01"
    )

    let data = try CartesiaWebSocketSpeechService.makeGenerationPayload(
      CartesiaStreamingSpeechInput(configuration: config, text: ""),
      contextID: "ctx-1",
      transcript: "partial summary text",
      continueGeneration: true
    )

    let body = try jsonBody(from: data)
    XCTAssertEqual(body["context_id"] as? String, "ctx-1")
    XCTAssertEqual(body["transcript"] as? String, "partial summary text")
    XCTAssertEqual(body["continue"] as? Bool, true)
  }

  private func jsonBody(from request: URLRequest) throws -> [String: Any] {
    let data = try XCTUnwrap(request.httpBody)
    return try jsonBody(from: data)
  }

  private func jsonBody(from data: Data) throws -> [String: Any] {
    let decoded = try JSONSerialization.jsonObject(with: data)
    return try XCTUnwrap(decoded as? [String: Any])
  }
}
