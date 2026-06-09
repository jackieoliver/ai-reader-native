import Foundation

public struct ProviderConfigurationSummary: Equatable, Sendable {
  public var envFileExists: Bool
  public var cartesiaConfigured: Bool
  public var cartesiaVoiceConfigured: Bool
  public var anthropicConfigured: Bool
  public var cartesiaModel: String
  public var cartesiaLanguage: String
  public var anthropicModel: String?
  public var missingKeys: [String]

  public var readyForRead: Bool {
    cartesiaConfigured && cartesiaVoiceConfigured
  }

  public var readyForSummary: Bool {
    anthropicConfigured
  }
}

public struct CartesiaConfiguration: Equatable, Sendable {
  public var apiKey: String
  public var modelID: String
  public var voiceID: String
  public var language: String
  public var version: String

  public init(apiKey: String, modelID: String, voiceID: String, language: String, version: String) {
    self.apiKey = apiKey
    self.modelID = modelID
    self.voiceID = voiceID
    self.language = language
    self.version = version
  }
}

public struct AnthropicConfiguration: Equatable, Sendable {
  public var apiKey: String
  public var modelID: String
  public var version: String
  public var maxTokens: Int

  public init(apiKey: String, modelID: String, version: String, maxTokens: Int) {
    self.apiKey = apiKey
    self.modelID = modelID
    self.version = version
    self.maxTokens = maxTokens
  }
}

public enum CartesiaSpeechModel: String, CaseIterable, Identifiable, Sendable {
  case sonic35 = "sonic-3.5"
  case sonic3 = "sonic-3"
  case sonicLatest = "sonic-latest"

  public static let defaultValue: CartesiaSpeechModel = .sonic35

  public var id: String { rawValue }

  public var title: String {
    switch self {
    case .sonic35:
      return "Cartesia Sonic 3.5"
    case .sonic3:
      return "Cartesia Sonic 3"
    case .sonicLatest:
      return "Cartesia Sonic Latest"
    }
  }
}

public enum AnthropicModel: String, CaseIterable, Identifiable, Sendable {
  case opus48 = "claude-opus-4-8"
  case sonnet46 = "claude-sonnet-4-6"
  case haiku45 = "claude-haiku-4-5"

  public static let defaultValue: AnthropicModel = .opus48

  public var id: String { rawValue }

  public var title: String {
    switch self {
    case .opus48:
      return "Claude Opus 4.8"
    case .sonnet46:
      return "Claude Sonnet 4.6"
    case .haiku45:
      return "Claude Haiku 4.5"
    }
  }
}

public struct ProviderConfigurationValues: Equatable, Sendable {
  public var cartesia: CartesiaConfiguration?
  public var anthropic: AnthropicConfiguration?
  public var missingKeys: [String]

  public var readyForRead: Bool {
    cartesia != nil
  }

  public var readyForSummary: Bool {
    anthropic != nil
  }
}

public enum ProviderConfigurationError: LocalizedError, Equatable, Sendable {
  case envFileMissing(URL)
  case missingKeys([String])

  public var errorDescription: String? {
    switch self {
    case .envFileMissing(let url):
      return "Missing provider configuration at \(url.path)."
    case .missingKeys(let keys):
      return "Missing provider keys: \(keys.joined(separator: ", "))."
    }
  }
}

public enum ProviderConfiguration {
  public static let defaultCartesiaModel = CartesiaSpeechModel.defaultValue.rawValue
  public static let defaultCartesiaVoiceID = "db6b0ed5-d5d3-463d-ae85-518a07d3c2b4"
  public static let defaultCartesiaVoiceName = "Skylar"
  public static let defaultCartesiaLanguage = "en"
  public static let defaultCartesiaVersion = "2026-03-01"
  public static let defaultAnthropicModel = AnthropicModel.defaultValue.rawValue
  public static let defaultAnthropicVersion = "2023-06-01"
  public static let defaultAnthropicMaxTokens = 1500

  public static func summarize(envFileURL: URL = AIReaderPaths.envFileURL()) -> ProviderConfigurationSummary {
    let fileManager = FileManager.default
    guard let envFile = try? loadEnvIfPresent(envFileURL) else {
      return ProviderConfigurationSummary(
        envFileExists: fileManager.fileExists(atPath: envFileURL.path),
        cartesiaConfigured: false,
        cartesiaVoiceConfigured: false,
        anthropicConfigured: false,
        cartesiaModel: defaultCartesiaModel,
        cartesiaLanguage: defaultCartesiaLanguage,
        anthropicModel: nil,
        missingKeys: ["CARTESIA_API_KEY", "CARTESIA_VOICE_ID", "ANTHROPIC_API_KEY"]
      )
    }

    let cartesiaConfigured = envFile.value(for: "CARTESIA_API_KEY") != nil
    let cartesiaVoiceConfigured = envFile.value(for: "CARTESIA_VOICE_ID") != nil
    let anthropicConfigured = envFile.value(for: "ANTHROPIC_API_KEY") != nil
    var missing: [String] = []
    if !cartesiaConfigured {
      missing.append("CARTESIA_API_KEY")
    }
    if !cartesiaVoiceConfigured {
      missing.append("CARTESIA_VOICE_ID")
    }
    if !anthropicConfigured {
      missing.append("ANTHROPIC_API_KEY")
    }

    return ProviderConfigurationSummary(
      envFileExists: true,
      cartesiaConfigured: cartesiaConfigured,
      cartesiaVoiceConfigured: cartesiaVoiceConfigured,
      anthropicConfigured: anthropicConfigured,
      cartesiaModel: supportedCartesiaModel(envFile.value(for: "CARTESIA_MODEL")),
      cartesiaLanguage: envFile.value(for: "CARTESIA_LANGUAGE") ?? defaultCartesiaLanguage,
      anthropicModel: supportedAnthropicModel(envFile.value(for: "ANTHROPIC_MODEL")),
      missingKeys: missing
    )
  }

  public static func load(envFileURL: URL = AIReaderPaths.envFileURL()) throws -> ProviderConfigurationValues {
    let envFile = try loadEnvIfPresent(envFileURL)
    let cartesiaAPIKey = envFile.value(for: "CARTESIA_API_KEY")
    let cartesiaVoiceID = envFile.value(for: "CARTESIA_VOICE_ID")
    let anthropicAPIKey = envFile.value(for: "ANTHROPIC_API_KEY")

    var missing: [String] = []
    if cartesiaAPIKey == nil {
      missing.append("CARTESIA_API_KEY")
    }
    if cartesiaVoiceID == nil {
      missing.append("CARTESIA_VOICE_ID")
    }
    if anthropicAPIKey == nil {
      missing.append("ANTHROPIC_API_KEY")
    }

    let cartesia = cartesiaAPIKey.flatMap { apiKey in
      cartesiaVoiceID.map { voiceID in
        CartesiaConfiguration(
          apiKey: apiKey,
          modelID: supportedCartesiaModel(envFile.value(for: "CARTESIA_MODEL")),
          voiceID: voiceID,
          language: envFile.value(for: "CARTESIA_LANGUAGE") ?? defaultCartesiaLanguage,
          version: envFile.value(for: "CARTESIA_VERSION") ?? defaultCartesiaVersion
        )
      }
    }

    let anthropic = anthropicAPIKey.map { apiKey in
      AnthropicConfiguration(
        apiKey: apiKey,
        modelID: supportedAnthropicModel(envFile.value(for: "ANTHROPIC_MODEL")),
        version: envFile.value(for: "ANTHROPIC_VERSION") ?? defaultAnthropicVersion,
        maxTokens: parsePositiveInt(envFile.value(for: "ANTHROPIC_MAX_TOKENS"))
          ?? defaultAnthropicMaxTokens
      )
    }

    return ProviderConfigurationValues(
      cartesia: cartesia,
      anthropic: anthropic,
      missingKeys: missing
    )
  }

  public static func requireReadConfiguration(
    envFileURL: URL = AIReaderPaths.envFileURL()
  ) throws -> CartesiaConfiguration {
    let values = try load(envFileURL: envFileURL)
    guard let cartesia = values.cartesia else {
      let readKeys = values.missingKeys.filter { $0.hasPrefix("CARTESIA_") }
      throw ProviderConfigurationError.missingKeys(readKeys)
    }
    return cartesia
  }

  public static func requireCartesiaAPIKey(envFileURL: URL = AIReaderPaths.envFileURL()) throws -> String {
    let envFile = try loadEnvIfPresent(envFileURL)
    guard let cartesiaAPIKey = envFile.value(for: "CARTESIA_API_KEY") else {
      throw ProviderConfigurationError.missingKeys(["CARTESIA_API_KEY"])
    }
    return cartesiaAPIKey
  }

  public static func requireAnthropicConfiguration(
    envFileURL: URL = AIReaderPaths.envFileURL()
  ) throws -> AnthropicConfiguration {
    let values = try load(envFileURL: envFileURL)
    guard let anthropic = values.anthropic else {
      let anthropicKeys = values.missingKeys.filter { $0.hasPrefix("ANTHROPIC_") }
      throw ProviderConfigurationError.missingKeys(anthropicKeys)
    }
    return anthropic
  }

  public static func currentCartesiaVoiceID(envFileURL: URL = AIReaderPaths.envFileURL()) -> String? {
    guard let envFile = try? loadEnvIfPresent(envFileURL) else {
      return nil
    }
    return envFile.value(for: "CARTESIA_VOICE_ID")
  }

  public static func supportedCartesiaModel(_ rawValue: String?) -> String {
    guard let rawValue, let model = CartesiaSpeechModel(rawValue: rawValue) else {
      return defaultCartesiaModel
    }
    return model.rawValue
  }

  public static func supportedAnthropicModel(_ rawValue: String?) -> String {
    guard let rawValue, let model = AnthropicModel(rawValue: rawValue) else {
      return defaultAnthropicModel
    }
    return model.rawValue
  }

  public static func requireSummaryConfiguration(
    envFileURL: URL = AIReaderPaths.envFileURL()
  ) throws -> (CartesiaConfiguration, AnthropicConfiguration) {
    let values = try load(envFileURL: envFileURL)
    guard let cartesia = values.cartesia, let anthropic = values.anthropic else {
      throw ProviderConfigurationError.missingKeys(values.missingKeys)
    }
    return (cartesia, anthropic)
  }

  private static func parsePositiveInt(_ rawValue: String?) -> Int? {
    guard let rawValue, let value = Int(rawValue), value > 0 else {
      return nil
    }
    return value
  }

  private static func loadEnvIfPresent(_ envFileURL: URL) throws -> EnvFile {
    guard FileManager.default.fileExists(atPath: envFileURL.path) else {
      return EnvFile(values: [:])
    }
    return try EnvFile.load(from: envFileURL)
  }
}
