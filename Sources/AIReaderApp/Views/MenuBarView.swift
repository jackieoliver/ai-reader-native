import AIReaderCore
import AppKit
import SwiftUI

struct MenuBarView: View {
  @EnvironmentObject private var controller: ReaderController
  @AppStorage(PreferenceKeys.volumeMultiplier, store: PreferenceKeys.defaults) private var volumeMultiplier = 1.0
  @AppStorage(PreferenceKeys.voiceProvider, store: PreferenceKeys.defaults) private var voiceProvider = VoiceProvider.cartesia.rawValue
  @AppStorage(PreferenceKeys.voiceModel, store: PreferenceKeys.defaults) private var voiceModel = ProviderConfiguration.defaultCartesiaModel
  @AppStorage(PreferenceKeys.voiceGender, store: PreferenceKeys.defaults) private var voiceGender = VoiceGender.feminine.rawValue
  @AppStorage(PreferenceKeys.voiceSelection, store: PreferenceKeys.defaults) private var voiceSelection = ProviderConfiguration.defaultCartesiaVoiceID
  @AppStorage(PreferenceKeys.summaryModel, store: PreferenceKeys.defaults) private var summaryModel = AnthropicModel.defaultValue.rawValue
  @AppStorage(PreferenceKeys.summaryPromptSelection, store: PreferenceKeys.defaults) private var summaryType = SummaryPrompt.defaultTypeID
  @AppStorage(PreferenceKeys.summaryHistoryEnabled, store: PreferenceKeys.defaults) private var summaryHistoryEnabled = false

  @State private var summaryTypes: [SummaryPromptType] = []
  @State private var launchAtLoginEnabled = false
  @State private var launchAtLoginCanChange = false
  @State private var launchAtLoginMessage: String?

  var body: some View {
    Group {
      Text(controller.status.title)

      Divider()

      quickActionsSection

      Divider()

      speedMenu
      volumeMenu
      voiceMenu

      Button("Clear History") {
        SummaryWindowPresenter.shared.clearHistory()
      }

      summaryMenu

      Divider()

      Button("API Keys...") {
        controller.openAPIKeysWindow()
      }

      settingsMenu

      Divider()

      Button("Quit") {
        NSApplication.shared.terminate(nil)
      }
    }
    .onAppear {
      summaryTypes = SummaryPrompt.availableTypes()
      syncSelectedModelFromEnv()
      syncSummaryModelFromEnv()
      syncSelectedVoiceIDFromEnv()
      syncLaunchAtLoginState()
      controller.ensureCartesiaVoicesLoaded(
        gender: VoiceGender(rawValue: voiceGender),
        language: controller.providerConfiguration.cartesiaLanguage
      )
      controller.openPermissionDashboardIfNeededFromMenuBar()
    }
    .onChange(of: voiceGender) { _, _ in
      controller.refreshCartesiaVoices(
        gender: VoiceGender(rawValue: voiceGender),
        language: controller.providerConfiguration.cartesiaLanguage
      )
    }
  }

  private var quickActionsSection: some View {
    Section("Quick Actions") {
      actionButton(.read)
      actionButton(.summarizeAndRead)
      actionButton(.pauseResume)
    }
  }

  private var speedMenu: some View {
    Menu("Speed") {
      Button("1.5x") {}
    }
    .disabled(voiceProvider == VoiceProvider.cartesia.rawValue)
  }

  private var volumeMenu: some View {
    Menu("Volume") {
      ForEach(volumeOptions, id: \.self) { volume in
        Button(selectedTitle(volumeTitle(volume), isSelected: volumeMultiplier == volume)) {
          volumeMultiplier = volume
        }
      }
    }
  }

  private var voiceMenu: some View {
    Menu("Voice") {
      Menu("Provider") {
        Button(selectedTitle(VoiceProvider.cartesia.rawValue, isSelected: voiceProvider == VoiceProvider.cartesia.rawValue)) {
          voiceProvider = VoiceProvider.cartesia.rawValue
        }
      }

      Menu("Model") {
        ForEach(CartesiaSpeechModel.allCases) { model in
          Button(selectedTitle(model.title, isSelected: voiceModel == model.rawValue)) {
            voiceModel = model.rawValue
            controller.selectCartesiaModel(model)
          }
        }
      }

      Menu("Gender") {
        ForEach(VoiceGender.allCases) { gender in
          Button(selectedTitle(gender.rawValue, isSelected: voiceGender == gender.rawValue)) {
            voiceGender = gender.rawValue
          }
        }
      }

      cartesiaVoiceMenu
    }
  }

  private var cartesiaVoiceMenu: some View {
    Menu("Voice") {
      if controller.cartesiaVoices.isEmpty {
        Text(controller.cartesiaVoicesLoading ? "Loading Cartesia Voices..." : "Cartesia Voices Auto-Load")
          .foregroundStyle(.secondary)
      } else {
        ForEach(controller.cartesiaVoices.prefix(12)) { voice in
          Button(selectedTitle(voice.displayName, isSelected: voiceSelection == voice.id)) {
            voiceSelection = voice.id
            controller.selectCartesiaVoice(voice)
          }
        }
      }
      Button("Refresh Cartesia List") {
        controller.refreshCartesiaVoices(
          gender: VoiceGender(rawValue: voiceGender),
          language: controller.providerConfiguration.cartesiaLanguage
        )
      }
    }
  }

  private var summaryMenu: some View {
    Menu("Summary") {
      Menu("Type") {
        ForEach(summaryTypes) { type in
          summaryTypeButton(type)
        }
      }

      Menu("Model") {
        ForEach(AnthropicModel.allCases) { model in
          Button(selectedTitle(model.title, isSelected: summaryModel == model.rawValue)) {
            summaryModel = model.rawValue
            controller.selectAnthropicModel(model)
          }
        }
      }

      Toggle("History", isOn: $summaryHistoryEnabled)

      Button("Open Prompts Folder") {
        NSWorkspace.shared.open(AIReaderPaths.promptsDirectoryURL())
      }
    }
  }

  @ViewBuilder
  private var settingsMenu: some View {
    Menu("Settings") {
      Button(selectedTitle("Launch at Login", isSelected: launchAtLoginEnabled)) {
        setLaunchAtLogin(!launchAtLoginEnabled)
      }
      .disabled(!launchAtLoginCanChange)

      if let launchAtLoginMessage {
        Text(launchAtLoginMessage)
          .foregroundStyle(.secondary)
      }

      Button("Permissions...") {
        controller.openPermissionDashboardWindow()
      }

      Button("Shortcuts...") {
        controller.openPreferencesWindow()
      }
    }
  }

  private func summaryTypeButton(_ type: SummaryPromptType) -> some View {
    Button(selectedTitle(type.title, isSelected: summaryType == type.id)) {
      let changed = summaryType != type.id
      summaryType = type.id
      if changed {
        controller.summaryPromptTypeDidChange()
      }
    }
  }

  private func actionButton(_ action: ReaderAction) -> some View {
    Button {
      controller.perform(action)
    } label: {
      Label(actionLabel(action), systemImage: action.systemImage)
    }
  }

  private func actionLabel(_ action: ReaderAction) -> String {
    guard let shortcut = action.shortcutText else {
      return action.title
    }
    return "\(action.title) — \(shortcut)"
  }

  private var volumeOptions: [Double] {
    [0.75, 1.0, 1.25, 1.5, 2.0]
  }

  private func volumeTitle(_ volume: Double) -> String {
    "\(Int((volume * 100).rounded()))%"
  }

  private func selectedTitle(_ title: String, isSelected: Bool) -> String {
    isSelected ? "\(title) ✓" : title
  }

  private func setLaunchAtLogin(_ isEnabled: Bool) {
    do {
      try LaunchAtLoginService.setEnabled(isEnabled)
      syncLaunchAtLoginState()
    } catch {
      syncLaunchAtLoginState()
      launchAtLoginMessage = error.localizedDescription
    }
  }

  private func syncLaunchAtLoginState() {
    let state = LaunchAtLoginService.currentState
    launchAtLoginEnabled = state.isEnabled
    launchAtLoginCanChange = state.canChange
    launchAtLoginMessage = state.message
  }

  private func syncSelectedVoiceIDFromEnv() {
    guard let configuredVoiceID = ProviderConfiguration.currentCartesiaVoiceID(), !configuredVoiceID.isEmpty else {
      return
    }
    voiceSelection = configuredVoiceID
  }

  private func syncSelectedModelFromEnv() {
    voiceModel = ProviderConfiguration.supportedCartesiaModel(controller.providerConfiguration.cartesiaModel)
  }

  private func syncSummaryModelFromEnv() {
    summaryModel = ProviderConfiguration.supportedAnthropicModel(controller.providerConfiguration.anthropicModel)
  }
}
