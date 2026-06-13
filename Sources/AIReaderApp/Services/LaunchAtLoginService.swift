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
        canChange: true,
        message: nil
      )
    @unknown default:
      return LaunchAtLoginState(
        isEnabled: false,
        canChange: false,
        message: "Launch at Login status unavailable."
      )
    }
  }

  static func diagnosticLines() -> [String] {
    let state = currentState
    return [
      "bundle_url=\(Bundle.main.bundleURL.path)",
      "bundle_identifier=\(Bundle.main.bundleIdentifier ?? "unknown")",
      "running_from_app_bundle=\(isRunningFromAppBundle)",
      "smappservice_status=\(statusName(SMAppService.mainApp.status))",
      "state_is_enabled=\(state.isEnabled)",
      "state_can_change=\(state.canChange)",
      "state_message=\(state.message ?? "")",
    ]
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

  private static func statusName(_ status: SMAppService.Status) -> String {
    switch status {
    case .enabled:
      return "enabled"
    case .notRegistered:
      return "not_registered"
    case .requiresApproval:
      return "requires_approval"
    case .notFound:
      return "not_found"
    @unknown default:
      return "unknown"
    }
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
