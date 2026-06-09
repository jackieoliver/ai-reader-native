import AppKit
import Foundation

public enum TextInputSource: String, Equatable, Sendable {
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

public enum TextCaptureError: LocalizedError, Equatable, Sendable {
  case missingClipboardText

  public var errorDescription: String? {
    switch self {
    case .missingClipboardText:
      return "Copy text before triggering AI Reader."
    }
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

private extension Optional where Wrapped == String {
  var normalizedCapturedText: String? {
    guard let text = self?.trimmingCharacters(in: .whitespacesAndNewlines),
      !text.isEmpty
    else {
      return nil
    }
    return text
  }
}
