import AIReaderCore
import AppKit
import SwiftUI

struct APIKeysView: View {
  @EnvironmentObject private var controller: ReaderController

  @State private var cartesiaAPIKey = ""
  @State private var anthropicAPIKey = ""

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      readinessHeader

      Form {
        Section("Keys") {
          KeyStatusRow(label: "Cartesia", status: controller.cartesiaKeyStatus)
          SecureField(
            cartesiaAPIKey.isEmpty && controller.providerConfiguration.cartesiaConfigured
              ? "Paste new Cartesia API key to replace saved key"
              : "Paste Cartesia API key",
            text: $cartesiaAPIKey
          )
          if !cartesiaAPIKey.isEmpty {
            Label("New Cartesia key ready to save.", systemImage: "arrow.down.to.line.compact")
              .font(.caption)
              .foregroundStyle(.secondary)
          }

          KeyStatusRow(label: "Anthropic", status: controller.anthropicKeyStatus)
          SecureField(
            anthropicAPIKey.isEmpty && controller.providerConfiguration.anthropicConfigured
              ? "Paste new Anthropic API key to replace saved key"
              : "Paste Anthropic API key",
            text: $anthropicAPIKey
          )

          HStack {
            Button {
              NSWorkspace.shared.open(URL(string: "https://play.cartesia.ai/keys")!)
            } label: {
              Label("Cartesia Keys", systemImage: "key")
            }

            Button {
              NSWorkspace.shared.open(URL(string: "https://console.anthropic.com/settings/keys")!)
            } label: {
              Label("Anthropic Keys", systemImage: "key.horizontal")
            }

            Button {
              saveAndValidate()
            } label: {
              Label("Save & Check", systemImage: "checkmark.seal")
            }
            .keyboardShortcut(.defaultAction)
          }
        }

        Section("Setup") {
          LabeledContent("Default Voice", value: "\(ProviderConfiguration.defaultCartesiaVoiceName) selected automatically")
          LabeledContent("Voice Controls", value: "Preferences > Playback")
          LabeledContent("Speech Speed", value: "Fixed at 1.5x")
          Text(controller.cartesiaVoiceMessage)
            .font(.caption)
            .foregroundStyle(.secondary)

          HStack {
            Button {
              save()
              controller.testCartesiaVoice()
            } label: {
              Label("Test Cartesia Voice", systemImage: "speaker.wave.2")
            }

            Button {
              controller.refreshShellState()
            } label: {
              Label("Refresh Status", systemImage: "arrow.clockwise.circle")
            }

            Button {
              save()
              controller.testClaudeSummary()
            } label: {
              Label("Test Claude Summary", systemImage: "text.bubble")
            }
          }
        }
      }
      .formStyle(.grouped)
    }
    .padding(24)
    .frame(width: 620, height: 560)
    .onAppear {
      controller.refreshShellState()
    }
  }

  private var readinessHeader: some View {
    Label(
      readinessTitle,
      systemImage: controller.providerConfiguration.readyForRead ? "checkmark.circle.fill" : "exclamationmark.circle.fill"
    )
    .font(.headline.weight(.semibold))
    .foregroundStyle(controller.providerConfiguration.readyForRead ? .green : .orange)
  }

  private var readinessTitle: String {
    if controller.providerConfiguration.readyForRead {
      return "Cartesia Ready"
    }
    if controller.providerConfiguration.cartesiaConfigured {
      return "Cartesia Key Saved"
    }
    return "Cartesia Needs API Key"
  }

  private func save() {
    controller.saveProviderSettings(
      cartesiaAPIKey: cartesiaAPIKey,
      anthropicAPIKey: anthropicAPIKey,
      cartesiaVoiceID: ProviderConfiguration.currentCartesiaVoiceID() ?? ProviderConfiguration.defaultCartesiaVoiceID,
      cartesiaModel: controller.providerConfiguration.cartesiaModel,
      cartesiaLanguage: controller.providerConfiguration.cartesiaLanguage
    )
    cartesiaAPIKey = ""
    anthropicAPIKey = ""
  }

  private func saveAndValidate() {
    save()
  }
}

private struct KeyStatusRow: View {
  var label: String
  var status: ProviderKeyStatus

  var body: some View {
    HStack(spacing: 8) {
      Label(label, systemImage: status.systemImage)
        .foregroundStyle(color)
      Spacer()
      Text(statusText)
        .foregroundStyle(.secondary)
        .monospacedDigit()
    }
    .font(.callout.weight(.semibold))
  }

  private var color: Color {
    guard status.configured else {
      return .orange
    }
    if status.accepted == true {
      return .green
    }
    if status.accepted == false {
      return .red
    }
    return .green
  }

  private var statusText: String {
    guard status.configured else {
      return "Missing"
    }
    return "\(status.title) \(status.displayValue)"
  }
}
