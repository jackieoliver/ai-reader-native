import AIReaderCore
import AppKit
import SwiftUI

@MainActor
final class SummaryWindowState: ObservableObject {
  @Published var messages: [SummaryChatMessage] = []
  @Published var sourceCharacterCount = 0
  @Published var draftMessage = ""
  @Published var isSending = false
  @Published var statusText = ""

  private let anthropicSummary = AnthropicSummaryService()
  private var summaryContext = ""
  private var activeSummaryMessageID: SummaryChatMessage.ID?
  private var chatTask: Task<Void, Never>?

  var onSendChat: ((AnthropicChatInput, SummaryChatMessage.ID) -> Void)?
  var onSpeakText: ((String) -> Void)?
  var onPromptTypeChanged: (() -> Void)?

  var hasSummaryContent: Bool {
    !summaryContext.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  var latestAssistantText: String? {
    messages.last {
      $0.role == .assistant && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }?.text
  }

  var summary: String {
    summaryContext
  }

  var hasHistory: Bool {
    messages.contains { $0.isHistoryContext && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
      || !draftMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  func startSummary(sourceCharacterCount: Int, statusText: String) {
    let placeholder = SummaryChatMessage(role: .assistant, text: "")
    summaryContext = ""
    messages = [
      placeholder
    ]
    activeSummaryMessageID = placeholder.id
    self.sourceCharacterCount = sourceCharacterCount
    draftMessage = ""
    isSending = true
    self.statusText = statusText
  }

  func startSummaryRequest(
    configuration: AnthropicConfiguration,
    systemPrompt: String,
    sourceText: String,
    sourceCharacterCount: Int,
    statusText: String
  ) -> AnthropicChatInput {
    let priorMessages = PreferenceKeys.defaults.bool(forKey: PreferenceKeys.summaryHistoryEnabled)
      ? anthropicHistoryMessages()
      : []
    startSummary(
      sourceCharacterCount: sourceCharacterCount,
      statusText: statusText,
      preservingHistory: !priorMessages.isEmpty
    )

    return AnthropicChatInput(
      configuration: configuration,
      systemPrompt: systemPrompt,
      messages: SummaryHistoryContext.messages(sourceText: sourceText, priorMessages: priorMessages)
    )
  }

  func appendSummaryDelta(_ delta: String) {
    summaryContext += delta
    if let index = activeSummaryMessageIndex {
      messages[index].text += delta
      return
    }

    let message = SummaryChatMessage(role: .assistant, text: delta)
    messages.append(message)
    activeSummaryMessageID = message.id
  }

  func finishSummary(_ summary: String, statusText: String) {
    summaryContext = summary
    if let index = activeSummaryMessageIndex {
      messages[index].text = summary
    } else {
      let message = SummaryChatMessage(role: .assistant, text: summary)
      messages.append(message)
      activeSummaryMessageID = message.id
    }
    isSending = false
    self.statusText = statusText
  }

  func replaceSummary(_ summary: String, sourceCharacterCount: Int) {
    summaryContext = summary
    messages = [
      SummaryChatMessage(role: .assistant, text: summary)
    ]
    activeSummaryMessageID = messages.first?.id
    self.sourceCharacterCount = sourceCharacterCount
    draftMessage = ""
    isSending = false
    statusText = ""
  }

  func updateStatus(_ statusText: String) {
    self.statusText = statusText
  }

  func sendDraft() {
    let question = draftMessage.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !question.isEmpty, !isSending else {
      return
    }

    draftMessage = ""
    messages.append(SummaryChatMessage(role: .user, text: question))
    isSending = true
    statusText = "Claude is thinking."

    let input: AnthropicChatInput
    do {
      let anthropic = try ProviderConfiguration.requireAnthropicConfiguration()
      input = AnthropicChatInput(
        configuration: anthropic,
        systemPrompt: Self.followUpSystemPrompt,
        messages: anthropicMessages()
      )
    } catch {
      statusText = error.localizedDescription
      isSending = false
      return
    }

    if let onSendChat {
      let messageID = beginStreamingAssistantMessage(marker: nil)
      onSendChat(input, messageID)
      return
    }

    chatTask?.cancel()
    chatTask = Task { @MainActor [weak self] in
      guard let self else { return }
      do {
        let response = try await self.anthropicSummary.chat(input)
        self.messages.append(SummaryChatMessage(role: .assistant, text: response))
        self.statusText = ""
      } catch is CancellationError {
        return
      } catch {
        self.statusText = error.localizedDescription
      }
      self.isSending = false
    }
  }

  func requestSpeakLatest() {
    guard let latestAssistantText else { return }
    onSpeakText?(latestAssistantText)
  }

  func promptTypeChanged() {
    onPromptTypeChanged?()
  }

  func beginStreamingAssistantMessage(marker: String?) -> SummaryChatMessage.ID {
    if let marker {
      messages.append(SummaryChatMessage(role: .user, text: marker, isHistoryContext: false))
    }
    let placeholder = SummaryChatMessage(role: .assistant, text: "")
    messages.append(placeholder)
    activeSummaryMessageID = placeholder.id
    isSending = true
    return placeholder.id
  }

  func appendStreamingDelta(to id: SummaryChatMessage.ID, _ delta: String) {
    guard let index = messages.firstIndex(where: { $0.id == id }) else { return }
    messages[index].text += delta
  }

  func finishStreamingMessage(
    id: SummaryChatMessage.ID,
    text: String,
    statusText: String,
    asSummaryContext: Bool
  ) {
    if let index = messages.firstIndex(where: { $0.id == id }) {
      messages[index].text = text
    }
    if asSummaryContext {
      summaryContext = text
    }
    isSending = false
    self.statusText = statusText
  }

  func failStreamingMessage(id: SummaryChatMessage.ID, statusText: String) {
    if let index = messages.firstIndex(where: { $0.id == id }),
      messages[index].text.isEmpty
    {
      messages.remove(at: index)
    }
    isSending = false
    self.statusText = statusText
  }

  func copySummaryToPasteboard() {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(summaryContext, forType: .string)
  }

  func clearHistory() {
    draftMessage = ""
    if summaryContext.isEmpty {
      messages = []
      activeSummaryMessageID = nil
    } else {
      let message = SummaryChatMessage(role: .assistant, text: summaryContext, isHistoryContext: false)
      messages = [message]
      activeSummaryMessageID = message.id
    }
    statusText = "History cleared."
  }

  private func startSummary(
    sourceCharacterCount: Int,
    statusText: String,
    preservingHistory: Bool
  ) {
    let placeholder = SummaryChatMessage(role: .assistant, text: "")
    summaryContext = ""
    if preservingHistory {
      messages.append(
        SummaryChatMessage(
          role: .user,
          text: "Highlighted text selected (\(sourceCharacterCount) chars)."
        )
      )
      messages.append(placeholder)
    } else {
      messages = [placeholder]
    }
    activeSummaryMessageID = placeholder.id
    self.sourceCharacterCount = sourceCharacterCount
    draftMessage = ""
    isSending = true
    self.statusText = statusText
  }

  private var activeSummaryMessageIndex: [SummaryChatMessage].Index? {
    guard let activeSummaryMessageID else {
      return nil
    }
    return messages.firstIndex { $0.id == activeSummaryMessageID }
  }

  private func anthropicHistoryMessages() -> [AnthropicChatMessage] {
    messages.compactMap { message in
      guard message.isHistoryContext else {
        return nil
      }
      let content = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !content.isEmpty else {
        return nil
      }
      return AnthropicChatMessage(role: message.role.anthropicRole, content: content)
    }
  }

  private func anthropicMessages() -> [AnthropicChatMessage] {
    var apiMessages = [
      AnthropicChatMessage(
        role: .user,
        content: "Use this Claude-generated summary as the source context for the follow-up chat:\n\n\(summaryContext)"
      )
    ]

    apiMessages.append(contentsOf: anthropicHistoryMessages())
    return apiMessages
  }

  private static let followUpSystemPrompt = """
    You answer follow-up questions about a summary AI Reader generated, and your answer will be read aloud by a text-to-speech voice — so write for the ear, not the eye. Answer like me, Claude: direct and concrete, a little dry, with no filler or hedging. Lead with the answer in your first sentence; no preamble, and do not restate the question. Keep it short and conversational, ground it in the summary and the chat so far, and say any symbols, code, paths, or numbers the way a person would rather than reading them out. If the summary does not contain enough to answer, say so plainly rather than guessing.
    """
}

struct SummaryChatMessage: Identifiable, Equatable {
  enum Role: Equatable {
    case user
    case assistant

    var anthropicRole: AnthropicChatRole {
      switch self {
      case .user:
        return .user
      case .assistant:
        return .assistant
      }
    }
  }

  let id = UUID()
  var role: Role
  var text: String
  var isHistoryContext = true
}

@MainActor
final class SummaryWindowPresenter: NSObject, NSWindowDelegate {
  static let shared = SummaryWindowPresenter()

  private let state = SummaryWindowState()
  private var windowController: NSWindowController?

  var chatState: SummaryWindowState {
    state
  }

  func showWindowIfNeeded() {
    showWindow()
  }

  func show(summary: String, sourceCharacterCount: Int) {
    state.replaceSummary(summary, sourceCharacterCount: sourceCharacterCount)
    showWindow()
  }

  func startSummary(sourceCharacterCount: Int, statusText: String) {
    state.startSummary(sourceCharacterCount: sourceCharacterCount, statusText: statusText)
    showWindow()
  }

  func startSummaryRequest(
    configuration: AnthropicConfiguration,
    systemPrompt: String,
    sourceText: String,
    sourceCharacterCount: Int,
    statusText: String
  ) -> AnthropicChatInput {
    let input = state.startSummaryRequest(
      configuration: configuration,
      systemPrompt: systemPrompt,
      sourceText: sourceText,
      sourceCharacterCount: sourceCharacterCount,
      statusText: statusText
    )
    showWindow()
    return input
  }

  func appendSummaryDelta(_ delta: String) {
    state.appendSummaryDelta(delta)
  }

  func finishSummary(_ summary: String, statusText: String) {
    state.finishSummary(summary, statusText: statusText)
  }

  func updateStatus(_ statusText: String) {
    state.updateStatus(statusText)
  }

  func clearHistory() {
    state.clearHistory()
  }

  private func showWindow() {
    PermissionService.activateForUserFacingPermissionFlow()

    if let window = windowController?.window {
      window.makeKeyAndOrderFront(nil)
      NSApp.activate(ignoringOtherApps: true)
      return
    }

    let hostingController = NSHostingController(rootView: SummaryWindowView(state: state))
    let window = NSWindow(contentViewController: hostingController)
    window.title = "Claude Summary"
    window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
    window.isReleasedWhenClosed = false
    window.delegate = self
    window.setFrame(NSRect(x: 0, y: 0, width: 540, height: 340), display: false)
    window.center()

    let windowController = NSWindowController(window: window)
    self.windowController = windowController
    windowController.showWindow(nil)
    window.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
  }

  func windowWillClose(_ notification: Notification) {
    guard notification.object as? NSWindow === windowController?.window else {
      return
    }
    windowController = nil

    DispatchQueue.main.async {
      AppActivationPolicyRestorer.restoreMenuBarPolicyIfNoVisibleWindows()
    }
  }
}

struct SummaryWindowView: View {
  @ObservedObject var state: SummaryWindowState
  @AppStorage(PreferenceKeys.summaryHistoryEnabled, store: PreferenceKeys.defaults) private var summaryHistoryEnabled = false
  @AppStorage(PreferenceKeys.summaryPromptSelection, store: PreferenceKeys.defaults) private var selectedSummaryPrompt = SummaryPrompt.defaultTypeID

  @State private var summaryTypes: [SummaryPromptType] = []

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        Label("Claude Summary", systemImage: "text.bubble")
          .font(.headline.weight(.semibold))
        Spacer()
        Text("\(state.summary.count) chars")
          .font(.caption)
          .foregroundStyle(.secondary)
          .monospacedDigit()
      }

      HStack(spacing: 8) {
        Button {
          state.clearHistory()
        } label: {
          Label("Clear History", systemImage: "trash")
        }
        .disabled(!state.hasHistory || state.isSending)

        Button {
          summaryHistoryEnabled.toggle()
        } label: {
          Label("History", systemImage: summaryHistoryEnabled ? "checkmark.square.fill" : "square")
        }

        Menu {
          ForEach(summaryTypes) { type in
            Button(selectedTitle(type.title, isSelected: selectedSummaryPrompt == type.id)) {
              let changed = selectedSummaryPrompt != type.id
              selectedSummaryPrompt = type.id
              if changed {
                state.promptTypeChanged()
              }
            }
          }
          Divider()
          Button {
            NSWorkspace.shared.open(AIReaderPaths.promptsDirectoryURL())
          } label: {
            Label("Open Prompts Folder", systemImage: "folder")
          }
        } label: {
          Label(selectedTypeTitle, systemImage: "doc.text")
        }

        Spacer(minLength: 0)
      }
      .controlSize(.small)

      ScrollViewReader { proxy in
        ScrollView {
          VStack(alignment: .leading, spacing: 10) {
            ForEach(state.messages) { message in
              SummaryChatBubble(message: message)
                .id(message.id)
            }
            if state.isSending {
              ProgressView()
                .controlSize(.small)
                .padding(.leading, 4)
            }
            Color.clear
              .frame(height: 1)
              .id(Self.bottomAnchorID)
          }
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onChange(of: state.messages.count) { _, _ in
          scrollToBottom(proxy)
        }
        .onChange(of: state.messages.map(\.text).joined(separator: "\n").count) { _, _ in
          scrollToBottom(proxy)
        }
        .onChange(of: state.isSending) { _, _ in
          scrollToBottom(proxy)
        }
      }
      .background(Color(nsColor: .textBackgroundColor))
      .clipShape(RoundedRectangle(cornerRadius: 8))
      .overlay {
        RoundedRectangle(cornerRadius: 8)
          .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
      }

      HStack(spacing: 8) {
        TextField("Ask about the summary", text: $state.draftMessage)
          .textFieldStyle(.roundedBorder)
          .onSubmit {
            state.sendDraft()
          }
          .disabled(state.isSending)
        Button {
          state.sendDraft()
        } label: {
          Label("Send", systemImage: "paperplane.fill")
        }
        .disabled(state.draftMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || state.isSending)
      }

      HStack {
        Text("Source \(state.sourceCharacterCount) chars")
          .font(.caption)
          .foregroundStyle(.secondary)
          .monospacedDigit()
        if !state.statusText.isEmpty {
          Text(state.statusText)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
        Spacer()
        Button {
          state.requestSpeakLatest()
        } label: {
          Label("Read Aloud", systemImage: "speaker.wave.2")
        }
        .disabled(state.latestAssistantText == nil || state.isSending)
        Button {
          state.copySummaryToPasteboard()
        } label: {
          Label("Copy Summary", systemImage: "doc.on.doc")
        }
      }
    }
    .padding(16)
    .frame(minWidth: 440, minHeight: 360)
    .onAppear {
      summaryTypes = SummaryPrompt.availableTypes()
    }
  }

  private static let bottomAnchorID = "summary-window-bottom-anchor"

  private var selectedTypeTitle: String {
    summaryTypes.first { $0.id == selectedSummaryPrompt }?.title
      ?? SummaryPrompt.prettyTitle(selectedSummaryPrompt)
  }

  private func scrollToBottom(_ proxy: ScrollViewProxy) {
    Task { @MainActor in
      await Task.yield()
      withAnimation(.easeOut(duration: 0.12)) {
        proxy.scrollTo(Self.bottomAnchorID, anchor: .bottom)
      }
    }
  }

  private func selectedTitle(_ title: String, isSelected: Bool) -> String {
    isSelected ? "\(title) ✓" : title
  }
}

private struct SummaryChatBubble: View {
  var message: SummaryChatMessage

  var body: some View {
    HStack {
      if message.role == .user {
        Spacer(minLength: 36)
      }

      Text(message.text)
        .textSelection(.enabled)
        .fixedSize(horizontal: false, vertical: true)
        .padding(10)
        .frame(maxWidth: .infinity, alignment: message.role == .user ? .trailing : .leading)
      .background(background)
      .clipShape(RoundedRectangle(cornerRadius: 8))
      .overlay(alignment: .topLeading) {
        if message.text.isEmpty {
          Text("Streaming Claude summary...")
            .foregroundStyle(.secondary)
            .padding(10)
        }
      }

      if message.role == .assistant {
        Spacer(minLength: 36)
      }
    }
  }

  private var background: Color {
    switch message.role {
    case .user:
      return Color(nsColor: .selectedContentBackgroundColor).opacity(0.18)
    case .assistant:
      return Color(nsColor: .controlBackgroundColor)
    }
  }
}
