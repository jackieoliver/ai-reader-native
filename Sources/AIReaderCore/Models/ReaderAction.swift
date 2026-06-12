import Foundation

public enum ReaderAction: String, CaseIterable, Identifiable, Sendable {
  case read
  case summarize
  case summarizeAndRead
  case pauseResume
  case stop
  case rewind
  case fastForward
  case startFromBeginning
  case replay

  public var id: String { rawValue }

  public var title: String {
    switch self {
    case .read:
      return "Read"
    case .summarize:
      return "Summarize"
    case .summarizeAndRead:
      return "Summarize and Read"
    case .pauseResume:
      return "Pause / Resume"
    case .stop:
      return "Stop"
    case .rewind:
      return "Rewind"
    case .fastForward:
      return "Fast Forward"
    case .startFromBeginning:
      return "Start from Beginning"
    case .replay:
      return "Replay"
    }
  }

  public var shortcutText: String? {
    switch self {
    case .read:
      return "Ctrl+Ctrl"
    case .summarizeAndRead:
      return "Ctrl+Opt"
    case .pauseResume:
      return "Ctrl+S"
    case .rewind:
      return "Ctrl+A"
    case .fastForward:
      return "Ctrl+D"
    default:
      return nil
    }
  }

  public var systemImage: String {
    switch self {
    case .read:
      return "speaker.wave.2"
    case .summarize:
      return "text.bubble"
    case .summarizeAndRead:
      return "text.badge.checkmark"
    case .pauseResume:
      return "pause.fill"
    case .stop:
      return "stop.fill"
    case .rewind:
      return "gobackward.10"
    case .fastForward:
      return "goforward.10"
    case .startFromBeginning:
      return "backward.end.fill"
    case .replay:
      return "arrow.clockwise"
    }
  }
}
