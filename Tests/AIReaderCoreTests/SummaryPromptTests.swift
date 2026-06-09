import AIReaderCore
import XCTest

final class SummaryPromptTests: XCTestCase {
  func testDefaultSummaryTypeIsBoilDown() {
    XCTAssertEqual(SummaryPrompt.defaultTypeID, "boil-down")
  }

  func testLoadTypeReadsPromptFileFreshEachCall() throws {
    let directory = try temporaryDirectory()
    let promptURL = directory.appendingPathComponent("boil-down.md")
    try "first prompt".write(to: promptURL, atomically: true, encoding: .utf8)

    XCTAssertEqual(SummaryPrompt.load(typeID: "boil-down", directory: directory), "first prompt")

    try "updated prompt".write(to: promptURL, atomically: true, encoding: .utf8)

    XCTAssertEqual(SummaryPrompt.load(typeID: "boil-down", directory: directory), "updated prompt")
  }

  func testAvailableTypesIncludesShippedBoilDownPrompt() throws {
    let directory = try temporaryDirectory()

    let types = SummaryPrompt.availableTypes(directory: directory)

    XCTAssertTrue(types.contains { $0.id == "boil-down" && $0.title == "Boil Down" })
    XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("boil-down.md").path))
  }

  private func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }
}
