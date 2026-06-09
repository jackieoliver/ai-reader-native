import Foundation

public enum ReaderStatus: String, CaseIterable, Identifiable, Sendable {
  case ready
  case reading
  case summarizing
  case paused
  case missingClipboardText
  case missingPermission
  case failed

  public var id: String { rawValue }

  public var title: String {
    switch self {
    case .ready:
      return "Ready"
    case .reading:
      return "Reading..."
    case .summarizing:
      return "Summarizing..."
    case .paused:
      return "Paused"
    case .missingClipboardText:
      return "No Copied Text"
    case .missingPermission:
      return "Needs Permission"
    case .failed:
      return "Failed"
    }
  }

  public var systemImage: String {
    switch self {
    case .ready:
      return "speaker.wave.2.circle"
    case .reading:
      return "speaker.wave.3"
    case .summarizing:
      return "text.bubble"
    case .paused:
      return "pause.circle"
    case .missingClipboardText:
      return "doc.on.clipboard"
    case .missingPermission:
      return "exclamationmark.shield"
    case .failed:
      return "exclamationmark.triangle"
    }
  }
}
