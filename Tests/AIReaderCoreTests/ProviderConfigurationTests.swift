import AIReaderCore
import XCTest

final class ProviderConfigurationTests: XCTestCase {
  func testSummaryCanBeReadyBeforeCartesiaVoiceIsSelected() throws {
    let envURL = try temporaryEnv(
      """
      CARTESIA_API_KEY=cartesia-key
      ANTHROPIC_API_KEY=anthropic-key
      """
    )

    let summary = ProviderConfiguration.summarize(envFileURL: envURL)

    XCTAssertTrue(summary.cartesiaConfigured)
    XCTAssertFalse(summary.cartesiaVoiceConfigured)
    XCTAssertFalse(summary.readyForRead)
    XCTAssertTrue(summary.readyForSummary)
    XCTAssertEqual(summary.missingKeys, ["CARTESIA_VOICE_ID"])

    let values = try ProviderConfiguration.load(envFileURL: envURL)
    XCTAssertFalse(values.readyForRead)
    XCTAssertTrue(values.readyForSummary)
  }

  func testLoadBuildsProviderConfigurationsWithDefaults() throws {
    let envURL = try temporaryEnv(
      """
      CARTESIA_API_KEY=cartesia-key
      CARTESIA_VOICE_ID=voice-id
      ANTHROPIC_API_KEY=anthropic-key
      """
    )

    let values = try ProviderConfiguration.load(envFileURL: envURL)

    XCTAssertEqual(values.cartesia?.modelID, "sonic-3.5")
    XCTAssertEqual(values.cartesia?.voiceID, "voice-id")
    XCTAssertEqual(values.cartesia?.language, "en")
    XCTAssertEqual(values.cartesia?.version, "2026-03-01")
    XCTAssertEqual(values.anthropic?.modelID, "claude-opus-4-8")
    XCTAssertEqual(values.anthropic?.version, "2023-06-01")
    XCTAssertEqual(values.anthropic?.maxTokens, 1500)
    XCTAssertTrue(values.readyForRead)
    XCTAssertTrue(values.readyForSummary)
  }

  func testRequireAnthropicConfigurationUsesDefaults() throws {
    let envURL = try temporaryEnv(
      """
      ANTHROPIC_API_KEY=anthropic-key
      """
    )

    let anthropic = try ProviderConfiguration.requireAnthropicConfiguration(envFileURL: envURL)

    XCTAssertEqual(anthropic.apiKey, "anthropic-key")
    XCTAssertEqual(anthropic.modelID, "claude-opus-4-8")
    XCTAssertEqual(anthropic.version, "2023-06-01")
    XCTAssertEqual(anthropic.maxTokens, 1500)
  }

  func testUnsupportedModelsFallBackBeforeRequestsAreBuilt() throws {
    let envURL = try temporaryEnv(
      """
      CARTESIA_API_KEY=cartesia-key
      CARTESIA_MODEL=sonic-retired
      CARTESIA_VOICE_ID=voice-id
      ANTHROPIC_API_KEY=anthropic-key
      ANTHROPIC_MODEL=claude-retired
      """
    )

    let summary = ProviderConfiguration.summarize(envFileURL: envURL)
    let values = try ProviderConfiguration.load(envFileURL: envURL)

    XCTAssertEqual(summary.cartesiaModel, "sonic-3.5")
    XCTAssertEqual(summary.anthropicModel, "claude-opus-4-8")
    XCTAssertEqual(values.cartesia?.modelID, "sonic-3.5")
    XCTAssertEqual(values.anthropic?.modelID, "claude-opus-4-8")
  }

  func testSonicLatestIsSupported() {
    XCTAssertEqual(ProviderConfiguration.supportedCartesiaModel("sonic-latest"), "sonic-latest")
  }

  private func temporaryEnv(_ contents: String) throws -> URL {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appendingPathComponent(".env")
    try contents.write(to: url, atomically: true, encoding: .utf8)
    return url
  }
}
