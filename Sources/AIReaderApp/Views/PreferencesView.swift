import SwiftUI

struct PreferencesView: View {
  var body: some View {
    Form {
      Section("Shortcuts") {
        shortcutRow("Read", "Ctrl+Ctrl")
        shortcutRow("Summarize and Read", "Ctrl+Opt")
        shortcutRow("Pause / Resume", "Ctrl+S")
        shortcutRow("Stop", "Ctrl+B")
        shortcutRow("Rewind 10s", "Ctrl+A")
        shortcutRow("Fast Forward 10s", "Ctrl+D")
      }

      Section {
        Text("Shortcuts are fixed. Select text, then trigger AI Reader.")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
    .formStyle(.grouped)
    .frame(width: 380, height: 320)
  }

  private func shortcutRow(_ name: String, _ keys: String) -> some View {
    LabeledContent(name, value: keys)
  }
}
