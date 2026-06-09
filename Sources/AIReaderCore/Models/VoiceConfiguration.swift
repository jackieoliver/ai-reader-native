import Foundation

public enum VoiceGender: String, CaseIterable, Identifiable, Sendable {
  case feminine = "Feminine"
  case masculine = "Masculine"
  case genderNeutral = "Neutral"

  public var id: String { rawValue }

  public var cartesiaValue: String {
    switch self {
    case .feminine:
      return "feminine"
    case .masculine:
      return "masculine"
    case .genderNeutral:
      return "gender_neutral"
    }
  }
}

public enum VoiceProvider: String, CaseIterable, Identifiable, Sendable {
  case cartesia = "Cartesia"

  public var id: String { rawValue }
}
