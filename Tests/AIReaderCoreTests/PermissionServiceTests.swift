import AIReaderCore
import XCTest

final class PermissionServiceTests: XCTestCase {
  func testPermissionSnapshotSummarizesMissingPermissions() {
    let missing = PermissionSnapshot(accessibilityTrusted: false)
    XCTAssertFalse(missing.allRequiredGranted)
    XCTAssertEqual(missing.requiredSummary, "Required: Accessibility.")

    let granted = PermissionSnapshot(accessibilityTrusted: true)
    XCTAssertTrue(granted.allRequiredGranted)
    XCTAssertEqual(granted.requiredSummary, "Permissions are ready.")
  }

  func testAccessibilityRequestUsesAccessibilityAPI() {
    final class Probe: @unchecked Sendable {
      var requested = false
    }
    let probe = Probe()
    let platform = AIReaderPermissionPlatform(
      accessibilityTrusted: { false },
      accessibilityRequest: {
        probe.requested = true
        return true
      }
    )

    XCTAssertTrue(PermissionService.requestAccessibility(platform: platform))
    XCTAssertTrue(probe.requested)
  }

  func testPrivacyPaneURLPointsAtAccessibilitySettingsAnchor() {
    XCTAssertEqual(
      PermissionService.accessibilitySettingsURL,
      "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
    )
  }
}
