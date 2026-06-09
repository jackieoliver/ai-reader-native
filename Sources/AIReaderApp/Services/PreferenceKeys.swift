import AIReaderCore
import Foundation

enum PreferenceKeys {
  static var defaults: UserDefaults {
    AIReaderAppIdentity.current().userDefaults
  }

  static let voiceProvider = "AIReaderVoiceProvider"
  static let voiceModel = "AIReaderVoiceModel"
  static let voiceGender = "AIReaderVoiceGender"
  static let voiceSelection = "AIReaderVoiceSelection"
  static let volumeMultiplier = "AIReaderVolumeMultiplier"
  static let modifierTapInterval = "AIReaderModifierTapInterval"
  static let summaryHistoryEnabled = "AIReaderSummaryHistoryEnabled"
  static let summaryPromptSelection = "AIReaderSummaryPromptSelection"
  static let summaryModel = "AIReaderSummaryModel"
  private static let summaryPromptDefaultMigration = "AIReaderSummaryPromptDefaultMigrationBoilDown"

  static func currentSummaryPromptTypeID() -> String {
    migrateDefaultSummaryPromptSelectionIfNeeded()
    let stored = defaults.string(forKey: summaryPromptSelection)
    guard let stored, !stored.isEmpty else {
      return SummaryPrompt.defaultTypeID
    }
    return stored
  }

  static func migrateDefaultSummaryPromptSelectionIfNeeded() {
    guard !defaults.bool(forKey: summaryPromptDefaultMigration) else {
      return
    }

    let stored = defaults.string(forKey: summaryPromptSelection)
    if stored == nil || stored == "natural" {
      defaults.set(SummaryPrompt.defaultTypeID, forKey: summaryPromptSelection)
    }
    defaults.set(true, forKey: summaryPromptDefaultMigration)
  }
}
