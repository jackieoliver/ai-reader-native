import AIReaderCore
import AppKit

@MainActor
enum AppActivationPolicyRestorer {
  static func restoreMenuBarPolicyIfNoVisibleWindows() {
    let hasVisibleWindow = NSApp.windows.contains { window in
      window.isVisible && window.styleMask.contains(.titled)
    }
    guard !hasVisibleWindow else {
      return
    }

    PermissionService.restoreMenuBarActivationPolicy()
  }
}
