import AIReaderCore
import XCTest

final class ClipboardTextCaptureServiceTests: XCTestCase {
  func testSelectedTextIsCapturedAndTrimmed() throws {
    let service = ClipboardTextCaptureService(
      selectedTextProvider: TestSelectedTextProvider(result: .success(" selected text ")),
      clipboardProvider: TestClipboardProvider(text: " clipboard text ")
    )

    XCTAssertEqual(
      try service.capture(),
      CapturedText(text: "selected text", source: .accessibilitySelection)
    )
  }

  func testClipboardFallbackIncludesDirectSelectionFailure() throws {
    let service = ClipboardTextCaptureService(
      selectedTextProvider: TestSelectedTextProvider(
        result: .failure(.selectedTextUnavailable("attributeUnsupported"))
      ),
      clipboardProvider: TestClipboardProvider(text: " clipboard text ")
    )

    XCTAssertEqual(
      try service.capture(),
      CapturedText(
        text: "clipboard text",
        source: .clipboard,
        directSelectionFailure: .selectedTextUnavailable("attributeUnsupported")
      )
    )
  }

  func testWhitespaceSelectedTextFallsBackToClipboard() throws {
    let service = ClipboardTextCaptureService(
      selectedTextProvider: TestSelectedTextProvider(result: .success(" \n\t ")),
      clipboardProvider: TestClipboardProvider(text: " clipboard text ")
    )

    XCTAssertEqual(
      try service.capture(),
      CapturedText(
        text: "clipboard text",
        source: .clipboard,
        directSelectionFailure: .selectedTextEmpty
      )
    )
  }

  func testMissingSelectedAndClipboardTextThrowsWithDirectFailure() throws {
    let service = ClipboardTextCaptureService(
      selectedTextProvider: TestSelectedTextProvider(result: .failure(.accessibilityPermissionMissing)),
      clipboardProvider: TestClipboardProvider(text: nil)
    )

    XCTAssertThrowsError(try service.capture()) { error in
      XCTAssertEqual(
        error as? TextCaptureError,
        .missingCapturedText(selectionFailure: .accessibilityPermissionMissing)
      )
    }
  }

  func testWhitespaceClipboardTextThrowsWithDirectFailure() throws {
    let service = ClipboardTextCaptureService(
      selectedTextProvider: TestSelectedTextProvider(result: .failure(.selectedTextEmpty)),
      clipboardProvider: TestClipboardProvider(text: " \n\t ")
    )

    XCTAssertThrowsError(try service.capture()) { error in
      XCTAssertEqual(
        error as? TextCaptureError,
        .missingCapturedText(selectionFailure: .selectedTextEmpty)
      )
    }
  }
}

private struct TestSelectedTextProvider: SelectedTextProviding {
  var result: Result<String, TextSelectionCaptureFailure>

  func selectedText() throws -> String {
    switch result {
    case .success(let text):
      return text
    case .failure(let failure):
      throw failure
    }
  }
}

private struct TestClipboardProvider: ClipboardTextProviding {
  var text: String?

  func string() -> String? {
    text
  }
}
