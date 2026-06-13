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
  public var directSelectionFailure: TextSelectionCaptureFailure?

  public init(
    text: String,
    source: TextInputSource,
    directSelectionFailure: TextSelectionCaptureFailure? = nil
  ) {
    self.text = text
    self.source = source
    self.directSelectionFailure = directSelectionFailure
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
  case missingCapturedText(selectionFailure: TextSelectionCaptureFailure)

  public var errorDescription: String? {
    switch self {
    case .missingClipboardText:
      return "Select text before triggering AI Reader, or copy text for fallback."
    case .missingCapturedText(let selectionFailure):
      return "Select text before triggering AI Reader. Direct selection failed: \(selectionFailure.localizedDescription) "
        + "Clipboard fallback was empty."
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
  private let selectedTextProvider: SelectedTextProviding
  private let clipboardProvider: ClipboardTextProviding

  public init(
    selectedTextProvider: SelectedTextProviding = AccessibilitySelectedTextProvider(),
    clipboardProvider: ClipboardTextProviding = PasteboardClipboardTextProvider()
  ) {
    self.selectedTextProvider = selectedTextProvider
    self.clipboardProvider = clipboardProvider
  }

  public func capture() throws -> CapturedText {
    do {
      let selectedText = try selectedTextProvider.selectedText()
      if let normalizedSelectedText = selectedText.normalizedCapturedText {
        return CapturedText(text: normalizedSelectedText, source: .accessibilitySelection)
      }
      return try captureClipboardFallback(after: .selectedTextEmpty)
    } catch let selectionFailure as TextSelectionCaptureFailure {
      return try captureClipboardFallback(after: selectionFailure)
    } catch {
      return try captureClipboardFallback(after: .selectedTextUnavailable(error.localizedDescription))
    }
  }

  private func captureClipboardFallback(after selectionFailure: TextSelectionCaptureFailure) throws -> CapturedText {
    if let clipboardText = clipboardProvider.string().normalizedCapturedText {
      return CapturedText(
        text: clipboardText,
        source: .clipboard,
        directSelectionFailure: selectionFailure
      )
    }

    throw TextCaptureError.missingCapturedText(selectionFailure: selectionFailure)
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
