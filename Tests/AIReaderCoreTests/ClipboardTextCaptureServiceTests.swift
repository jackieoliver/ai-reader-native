import AIReaderCore
import XCTest

final class ClipboardTextCaptureServiceTests: XCTestCase {
  func testClipboardTextIsCapturedAndTrimmed() throws {
    let service = ClipboardTextCaptureService(
      clipboardProvider: TestClipboardProvider(text: " clipboard text ")
    )

    XCTAssertEqual(
      try service.capture(),
      CapturedText(text: "clipboard text", source: .clipboard)
    )
  }

  func testClipboardTextIsTheOnlyDefaultCaptureSource() throws {
    let service = ClipboardTextCaptureService(
      clipboardProvider: TestClipboardProvider(text: " clipboard text ")
    )

    XCTAssertEqual(
      try service.capture(),
      CapturedText(text: "clipboard text", source: .clipboard)
    )
  }

  func testMissingClipboardTextThrows() throws {
    let service = ClipboardTextCaptureService(
      clipboardProvider: TestClipboardProvider(text: nil)
    )

    XCTAssertThrowsError(try service.capture()) { error in
      XCTAssertEqual(error as? TextCaptureError, .missingClipboardText)
    }
  }

  func testWhitespaceClipboardTextThrows() throws {
    let service = ClipboardTextCaptureService(
      clipboardProvider: TestClipboardProvider(text: " \n\t ")
    )

    XCTAssertThrowsError(try service.capture()) { error in
      XCTAssertEqual(error as? TextCaptureError, .missingClipboardText)
    }
  }
}

private struct TestClipboardProvider: ClipboardTextProviding {
  var text: String?

  func string() -> String? {
    text
  }
}
