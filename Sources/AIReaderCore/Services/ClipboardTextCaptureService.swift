import AppKit
@preconcurrency import ApplicationServices
import Foundation

public enum TextInputSource: String, Equatable, Sendable {
  case accessibilitySelection = "accessibility_selection"
  case clipboard
}

public struct CapturedText: Equatable, Sendable {
  public var text: String
  public var source: TextInputSource

  public init(text: String, source: TextInputSource) {
    self.text = text
    self.source = source
  }
}

public enum TextSelectionCaptureFailure: LocalizedError, Equatable, Sendable {
  case accessibilityPermissionMissing
  case focusedElementUnavailable(String)
  case selectedTextUnavailable(String)
  case selectedTextEmpty
  case selectedTextValueUnsupported(String)

  public var errorDescription: String? {
    switch self {
    case .accessibilityPermissionMissing:
      return "Accessibility is required to read the selected text."
    case .focusedElementUnavailable(let reason):
      return "Could not find the focused text element: \(reason)."
    case .selectedTextUnavailable(let reason):
      return "The focused element did not expose selected text: \(reason)."
    case .selectedTextEmpty:
      return "The focused element did not have selected text."
    case .selectedTextValueUnsupported(let valueType):
      return "The focused element returned unsupported selected-text value \(valueType)."
    }
  }
}

public enum TextCaptureError: LocalizedError, Equatable, Sendable {
  case missingClipboardText

  public var errorDescription: String? {
    switch self {
    case .missingClipboardText:
      return "Copy text before triggering AI Reader."
    }
  }
}

public protocol SelectedTextProviding: Sendable {
  func selectedText() throws -> String
}

public struct AccessibilitySelectedTextProvider: SelectedTextProviding {
  public init() {}

  public func selectedText() throws -> String {
    guard AXIsProcessTrusted() else {
      throw TextSelectionCaptureFailure.accessibilityPermissionMissing
    }

    let systemWideElement = AXUIElementCreateSystemWide()
    var focusedValue: CFTypeRef?
    let focusedResult = AXUIElementCopyAttributeValue(
      systemWideElement,
      kAXFocusedUIElementAttribute as CFString,
      &focusedValue
    )
    guard focusedResult == .success, let focusedValue else {
      throw TextSelectionCaptureFailure.focusedElementUnavailable(focusedResult.aiReaderDescription)
    }
    guard CFGetTypeID(focusedValue) == AXUIElementGetTypeID() else {
      throw TextSelectionCaptureFailure.focusedElementUnavailable(String(describing: type(of: focusedValue)))
    }

    let focusedElement = focusedValue as! AXUIElement
    var selectedTextValue: CFTypeRef?
    let selectedTextResult = AXUIElementCopyAttributeValue(
      focusedElement,
      kAXSelectedTextAttribute as CFString,
      &selectedTextValue
    )
    guard selectedTextResult == .success, let selectedTextValue else {
      throw TextSelectionCaptureFailure.selectedTextUnavailable(selectedTextResult.aiReaderDescription)
    }
    guard let selectedText = selectedTextValue as? String else {
      throw TextSelectionCaptureFailure.selectedTextValueUnsupported(String(describing: type(of: selectedTextValue)))
    }

    return selectedText
  }
}

public protocol ClipboardTextProviding: Sendable {
  func string() -> String?
}

public struct PasteboardClipboardTextProvider: ClipboardTextProviding {
  public init() {}

  public func string() -> String? {
    NSPasteboard.general.string(forType: .string)
  }
}

public final class ClipboardTextCaptureService {
  private let clipboardProvider: ClipboardTextProviding

  public init(
    clipboardProvider: ClipboardTextProviding = PasteboardClipboardTextProvider()
  ) {
    self.clipboardProvider = clipboardProvider
  }

  public func capture() throws -> CapturedText {
    if let clipboardText = clipboardProvider.string().normalizedCapturedText {
      return CapturedText(text: clipboardText, source: .clipboard)
    }

    throw TextCaptureError.missingClipboardText
  }
}

private extension AXError {
  var aiReaderDescription: String {
    String(describing: self)
  }
}

private extension String {
  var normalizedCapturedText: String? {
    let text = trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else {
      return nil
    }
    return text
  }
}

private extension Optional where Wrapped == String {
  var normalizedCapturedText: String? {
    self?.normalizedCapturedText
  }
}
