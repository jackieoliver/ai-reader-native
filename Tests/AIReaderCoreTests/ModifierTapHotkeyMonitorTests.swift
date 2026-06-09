@testable import AIReaderCore
import CoreGraphics
import XCTest

final class ModifierTapHotkeyMonitorTests: XCTestCase {
  func testControlASDBMapToPlaybackGestures() {
    XCTAssertEqual(
      ModifierTapHotkeyMonitor.playbackKeyGesture(keyCode: 0, flags: .maskControl),
      .rewind
    )
    XCTAssertEqual(
      ModifierTapHotkeyMonitor.playbackKeyGesture(keyCode: 1, flags: .maskControl),
      .pauseResume
    )
    XCTAssertEqual(
      ModifierTapHotkeyMonitor.playbackKeyGesture(keyCode: 2, flags: .maskControl),
      .fastForward
    )
    XCTAssertEqual(
      ModifierTapHotkeyMonitor.playbackKeyGesture(keyCode: 11, flags: .maskControl),
      .stop
    )
  }

  func testPlaybackGesturesRequireOnlyControl() {
    XCTAssertNil(ModifierTapHotkeyMonitor.playbackKeyGesture(keyCode: 0, flags: []))
    XCTAssertNil(ModifierTapHotkeyMonitor.playbackKeyGesture(keyCode: 0, flags: [.maskControl, .maskAlternate]))
    XCTAssertNil(ModifierTapHotkeyMonitor.playbackKeyGesture(keyCode: 0, flags: [.maskControl, .maskCommand]))
    XCTAssertNil(ModifierTapHotkeyMonitor.playbackKeyGesture(keyCode: 3, flags: .maskControl))
  }

  func testReaderActionsAdvertiseImplementedShortcuts() {
    XCTAssertEqual(ReaderAction.read.shortcutText, "Ctrl+Ctrl")
    XCTAssertEqual(ReaderAction.summarizeAndRead.shortcutText, "Ctrl+Opt")
    XCTAssertEqual(ReaderAction.rewind.shortcutText, "Ctrl+A")
    XCTAssertEqual(ReaderAction.pauseResume.shortcutText, "Ctrl+S")
    XCTAssertEqual(ReaderAction.fastForward.shortcutText, "Ctrl+D")
    XCTAssertEqual(ReaderAction.stop.shortcutText, "Ctrl+B")
    XCTAssertNil(ReaderAction.summarize.shortcutText)
    XCTAssertNil(ReaderAction.startFromBeginning.shortcutText)
    XCTAssertNil(ReaderAction.replay.shortcutText)
  }
}
