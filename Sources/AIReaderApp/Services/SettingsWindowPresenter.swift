import AIReaderCore
import AppKit
import SwiftUI

@MainActor
final class SettingsWindowPresenter: NSObject, NSWindowDelegate {
  static let shared = SettingsWindowPresenter()

  private var permissionWindowController: NSWindowController?
  private var preferencesWindowController: NSWindowController?
  private var apiKeysWindowController: NSWindowController?

  func showPermissions(controller: ReaderController) {
    PermissionService.activateForUserFacingPermissionFlow()

    if let window = permissionWindowController?.window {
      window.makeKeyAndOrderFront(nil)
      NSApp.activate(ignoringOtherApps: true)
      return
    }

    let hostingController = NSHostingController(
      rootView: PermissionDashboardView()
        .environmentObject(controller)
    )
    let window = NSWindow(contentViewController: hostingController)
    window.title = Self.versionedWindowTitle(suffix: "Permissions")
    window.styleMask = [.titled, .closable, .miniaturizable]
    window.isReleasedWhenClosed = false
    window.delegate = self
    window.center()

    let windowController = NSWindowController(window: window)
    self.permissionWindowController = windowController
    windowController.showWindow(nil)
    window.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
  }

  func showPreferences(controller: ReaderController) {
    PermissionService.activateForUserFacingPermissionFlow()

    if let window = preferencesWindowController?.window {
      window.makeKeyAndOrderFront(nil)
      NSApp.activate(ignoringOtherApps: true)
      return
    }

    let hostingController = NSHostingController(
      rootView: PreferencesView()
        .environmentObject(controller)
    )
    let window = NSWindow(contentViewController: hostingController)
    window.title = Self.versionedWindowTitle(suffix: "Shortcuts")
    window.styleMask = [.titled, .closable, .miniaturizable]
    window.isReleasedWhenClosed = false
    window.delegate = self
    window.center()

    let windowController = NSWindowController(window: window)
    self.preferencesWindowController = windowController
    windowController.showWindow(nil)
    window.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
  }

  func showAPIKeys(controller: ReaderController) {
    PermissionService.activateForUserFacingPermissionFlow()

    if let window = apiKeysWindowController?.window {
      window.makeKeyAndOrderFront(nil)
      NSApp.activate(ignoringOtherApps: true)
      return
    }

    let hostingController = NSHostingController(
      rootView: APIKeysView()
        .environmentObject(controller)
    )
    let window = NSWindow(contentViewController: hostingController)
    window.title = Self.versionedWindowTitle(suffix: "API Keys")
    window.styleMask = [.titled, .closable, .miniaturizable]
    window.isReleasedWhenClosed = false
    window.delegate = self
    window.center()

    let windowController = NSWindowController(window: window)
    self.apiKeysWindowController = windowController
    windowController.showWindow(nil)
    window.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
  }

  func windowWillClose(_ notification: Notification) {
    if notification.object as? NSWindow === permissionWindowController?.window {
      permissionWindowController = nil
    }
    if notification.object as? NSWindow === preferencesWindowController?.window {
      preferencesWindowController = nil
    }
    if notification.object as? NSWindow === apiKeysWindowController?.window {
      apiKeysWindowController = nil
    }
    if permissionWindowController == nil && preferencesWindowController == nil && apiKeysWindowController == nil {
      DispatchQueue.main.async {
        AppActivationPolicyRestorer.restoreMenuBarPolicyIfNoVisibleWindows()
      }
    }
  }

  private static func versionedWindowTitle(suffix: String) -> String {
    let identity = AIReaderAppIdentity.current()
    let productName = identity.kind == .dev ? "AI Reader Dev" : "AI Reader"
    let version = displayVersion(
      Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    )
    let build = displayBuild(
      Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
    )

    return "\(productName) V. \(version).\(build) \(suffix)"
  }

  private static func displayVersion(_ rawVersion: String?) -> String {
    let version = rawVersion?.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let version, !version.isEmpty else { return "0.1.0" }
    return version.split(separator: "-", maxSplits: 1).first.map(String.init) ?? version
  }

  private static func displayBuild(_ rawBuild: String?) -> String {
    let build = rawBuild?.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let build, !build.isEmpty else { return "0" }
    return build
  }
}
