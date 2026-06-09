import AIReaderCore
import XCTest

final class EnvFileTests: XCTestCase {
  func testParseIgnoresCommentsAndTrimsQuotes() {
    let values = EnvFile.parse(
      """
      # local config
      CARTESIA_API_KEY="cartesia-key"
      ANTHROPIC_API_KEY='anthropic-key'
      EMPTY=
      """
    )

    XCTAssertEqual(values["CARTESIA_API_KEY"], "cartesia-key")
    XCTAssertEqual(values["ANTHROPIC_API_KEY"], "anthropic-key")
    XCTAssertEqual(values["EMPTY"], "")
  }

  func testWriteMergedCanRemoveKeysAndPreserveConfig() throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appendingPathComponent(".env")
    try """
    CARTESIA_API_KEY=old-key
    CARTESIA_MODEL=sonic-3
    """.write(to: url, atomically: true, encoding: .utf8)

    try EnvFile.writeMerged(
      values: [
        "CARTESIA_MODEL": "custom-model",
        "CARTESIA_VOICE_ID": "voice id",
      ],
      removingKeys: ["CARTESIA_API_KEY"],
      to: url
    )

    let written = try EnvFile.load(from: url)
    XCTAssertNil(written.values["CARTESIA_API_KEY"])
    XCTAssertEqual(written.value(for: "CARTESIA_MODEL"), "custom-model")
    XCTAssertEqual(written.value(for: "CARTESIA_VOICE_ID"), "voice id")
  }

  func testWriteMergedRoundTripsEscapedQuotedValues() throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let url = directory.appendingPathComponent(".env")
    let secret = #"key "with quotes" and \slashes\ plus # hash"#

    try EnvFile.writeMerged(
      values: ["ANTHROPIC_API_KEY": secret],
      to: url
    )

    let written = try EnvFile.load(from: url)
    XCTAssertEqual(written.value(for: "ANTHROPIC_API_KEY"), secret)
  }
}
