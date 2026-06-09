import Foundation
import ServiceManagement

struct LaunchAtLoginState {
  var isEnabled: Bool
  var canChange: Bool
  var message: String?
}

enum LaunchAtLoginService {
  static var currentState: LaunchAtLoginState {
    guard isRunningFromAppBundle else {
      return LaunchAtLoginState(
        isEnabled: false,
        canChange: false,
        message: "Launch at Login requires the app bundle."
      )
    }

    switch SMAppService.mainApp.status {
    case .enabled:
      return LaunchAtLoginState(isEnabled: true, canChange: true, message: nil)
    case .notRegistered:
      return LaunchAtLoginState(isEnabled: false, canChange: true, message: nil)
    case .requiresApproval:
      return LaunchAtLoginState(
        isEnabled: false,
        canChange: true,
        message: "Approve in System Settings > Login Items."
      )
    case .notFound:
      return LaunchAtLoginState(
        isEnabled: false,
        canChange: false,
        message: "Install the app bundle before enabling login."
      )
    @unknown default:
      return LaunchAtLoginState(
        isEnabled: false,
        canChange: false,
        message: "Launch at Login status unavailable."
      )
    }
  }

  static func setEnabled(_ isEnabled: Bool) throws {
    guard isRunningFromAppBundle else {
      throw LaunchAtLoginError.requiresAppBundle
    }

    let service = SMAppService.mainApp
    if isEnabled {
      guard service.status != .enabled else {
        return
      }
      try service.register()
    } else {
      guard service.status == .enabled || service.status == .requiresApproval else {
        return
      }
      try service.unregister()
    }
  }

  private static var isRunningFromAppBundle: Bool {
    Bundle.main.bundleURL.pathExtension == "app"
  }
}

private enum LaunchAtLoginError: LocalizedError {
  case requiresAppBundle

  var errorDescription: String? {
    switch self {
    case .requiresAppBundle:
      return "Launch at Login requires the app bundle."
    }
  }
}
