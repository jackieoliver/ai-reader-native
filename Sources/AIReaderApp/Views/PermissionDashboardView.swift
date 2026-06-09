import SwiftUI

struct PermissionDashboardView: View {
  @EnvironmentObject private var controller: ReaderController

  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      ReadinessHeader(isReady: controller.shellReady)

      HStack(alignment: .center, spacing: 14) {
        Image(systemName: controller.permissions.accessibilityTrusted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
          .font(.title2)
          .foregroundStyle(controller.permissions.accessibilityTrusted ? .green : .orange)
          .frame(width: 28)

        VStack(alignment: .leading, spacing: 4) {
          Text("Accessibility")
            .font(.headline)
          Text("Enables read, summary, and playback keyboard shortcuts.")
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }

        Spacer(minLength: 16)

        if controller.permissions.accessibilityTrusted {
          Text("Granted")
            .font(.callout.weight(.semibold))
            .foregroundStyle(.green)
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(Capsule().fill(Color.green.opacity(0.12)))
        } else {
          Button("Grant", action: controller.requestAccessibility)
        }
      }
      .padding(.vertical, 12)

      HStack(spacing: 10) {
        Spacer()
        Button {
          controller.refreshShellState()
        } label: {
          Label("Check Again", systemImage: "arrow.clockwise")
        }
      }
    }
    .padding(24)
    .frame(width: 520)
    .onAppear {
      controller.refreshShellState()
    }
  }
}

private struct ReadinessHeader: View {
  var isReady: Bool

  var body: some View {
    Label(isReady ? "Ready" : "Not Ready", systemImage: isReady ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
      .font(.headline.weight(.semibold))
      .foregroundStyle(isReady ? .green : .orange)
  }
}
