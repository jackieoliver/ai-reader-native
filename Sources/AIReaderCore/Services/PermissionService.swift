import AppKit
@preconcurrency import ApplicationServices
import Foundation

public struct PermissionSnapshot: Equatable, Sendable {
  public var accessibilityTrusted: Bool

  public init(accessibilityTrusted: Bool) {
    self.accessibilityTrusted = accessibilityTrusted
  }

  public var allRequiredGranted: Bool {
    accessibilityTrusted
  }

  public var requiredSummary: String {
    accessibilityTrusted ? "Permissions are ready." : "Required: Accessibility."
  }
}

public struct PermissionRequestOutcome: Equatable, Sendable {
  public var granted: Bool
  public var message: String
}

public struct AIReaderPermissionPlatform: Sendable {
  public let accessibilityTrusted: @Sendable () -> Bool
  public let accessibilityRequest: @Sendable () -> Bool

  public init(
    accessibilityTrusted: @escaping @Sendable () -> Bool,
    accessibilityRequest: @escaping @Sendable () -> Bool
  ) {
    self.accessibilityTrusted = accessibilityTrusted
    self.accessibilityRequest = accessibilityRequest
  }

  public static let live = AIReaderPermissionPlatform(
    accessibilityTrusted: { AXIsProcessTrusted() },
    accessibilityRequest: {
      let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
      return AXIsProcessTrustedWithOptions(options)
    }
  )
}

public enum PermissionService {
  public static let accessibilitySettingsURL =
    "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
  private static let accessibilitySettingsFallbackURL =
    "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Accessibility"

  public static func snapshot(platform: AIReaderPermissionPlatform = .live) -> PermissionSnapshot {
    PermissionSnapshot(accessibilityTrusted: platform.accessibilityTrusted())
  }

  @discardableResult
  public static func requestAccessibility(platform: AIReaderPermissionPlatform = .live) -> Bool {
    platform.accessibilityRequest()
  }

  @discardableResult
  @MainActor
  public static func requestAccessibilityAndGuide(appDisplayName: String = "AI Reader") -> PermissionRequestOutcome {
    activateForUserFacingPermissionFlow()
    let granted = requestAccessibility()
    if !granted {
      openAccessibilitySettings()
    } else {
      restoreMenuBarActivationPolicySoon()
    }
    return PermissionRequestOutcome(
      granted: granted,
      message: granted
        ? "Accessibility is ready."
        : "Grant Accessibility in System Settings, then return to \(appDisplayName)."
    )
  }

  @MainActor
  @discardableResult
  public static func openAccessibilitySettings() -> Bool {
    openSystemSettingsPane(accessibilitySettingsURL, fallbackRawURL: accessibilitySettingsFallbackURL)
  }

  @MainActor
  public static func activateForUserFacingPermissionFlow() {
    NSApp.setActivationPolicy(.regular)
    NSApp.activate(ignoringOtherApps: true)
  }

  @MainActor
  public static func restoreMenuBarActivationPolicy() {
    NSApp.setActivationPolicy(.accessory)
  }

  @discardableResult
  @MainActor
  private static func openSystemSettingsPane(_ rawURL: String, fallbackRawURL: String) -> Bool {
    guard let url = URL(string: rawURL) else { return false }
    if NSWorkspace.shared.open(url) {
      activateSystemSettings()
      restoreMenuBarActivationPolicySoon()
      return true
    }
    guard let fallbackURL = URL(string: fallbackRawURL) else { return false }
    let opened = NSWorkspace.shared.open(fallbackURL)
    if opened {
      activateSystemSettings()
      restoreMenuBarActivationPolicySoon()
    }
    return opened
  }

  @MainActor
  private static func activateSystemSettings() {
    DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(300)) {
      for bundleIdentifier in ["com.apple.SystemSettings", "com.apple.systempreferences"] {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).first else {
          continue
        }
        if #available(macOS 14.0, *) {
          app.activate()
        } else {
          app.activate(options: [.activateIgnoringOtherApps])
        }
        return
      }
    }
  }

  @MainActor
  private static func restoreMenuBarActivationPolicySoon() {
    DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(2)) {
      guard NSApp.keyWindow == nil else {
        return
      }
      NSApp.setActivationPolicy(.accessory)
    }
  }
}
