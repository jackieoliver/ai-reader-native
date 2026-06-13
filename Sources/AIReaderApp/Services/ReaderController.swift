import AIReaderCore
import AppKit
import Foundation
import SwiftUI

@MainActor
final class ReaderController: ObservableObject {
  @Published var status: ReaderStatus = .ready {
    didSet {
      hotkeyMonitor.playbackKeyGesturesEnabled = status == .reading || status == .paused
    }
  }
  @Published var message = "Ready"
  @Published var permissions = PermissionService.snapshot()
  @Published var providerConfiguration = ProviderConfiguration.summarize()
  @Published var hotkeysRunning = false
  @Published var cartesiaVoices: [CartesiaVoice] = []
  @Published var cartesiaVoiceMessage = "Voices not loaded."
  @Published var cartesiaVoicesLoading = false
  @Published var cartesiaKeyStatus = ProviderKeyStatus.missing
  @Published var anthropicKeyStatus = ProviderKeyStatus.missing
  @Published var latencyMessage = "Latency not measured yet."

  private let hotkeyMonitor = ModifierTapHotkeyMonitor()
  private let textCapture = ClipboardTextCaptureService()
  private let anthropicSummary = AnthropicSummaryService()
  private let cartesiaDiagnosticSpeech = CartesiaSpeechService()
  private let cartesiaRealtimeSpeech = CartesiaWebSocketSpeechService()
  private let cartesiaVoiceService = CartesiaVoiceService()
  private let audioPlayback = AudioPlaybackService()
  private var permissionObservationTask: Task<Void, Never>?
  private var currentPipeline: Task<Void, Never>?
  private var pendingPipelineWork: (@MainActor () async -> Void)?
  private var pipelineStartWorker: Task<Void, Never>?
  private var readySettleTask: Task<Void, Never>?
  private var voiceTask: Task<Void, Never>?
  private var warmCartesiaTask: Task<Void, Never>?
  private var lastWarmCartesiaConfiguration: CartesiaConfiguration?
  private var lastVoiceLoadRequest: CartesiaVoiceLoadRequest?
  private var pauseTeardownTask: Task<Void, Never>?
  private var pipelineEpoch = 0
  private var lastCapturedText: String?
  private var lastSummaryWasSpoken = true
  private let streamingSampleRate = 44_100
  private let targetFirstAudioMS = 50.0
  private static let preemptionGraceMilliseconds = 250
  private static let pauseTeardownSeconds: TimeInterval = 120

  init() {
    PreferenceKeys.migrateDefaultSummaryPromptSelectionIfNeeded()

    let savedInterval = PreferenceKeys.defaults.double(forKey: PreferenceKeys.modifierTapInterval)
    if savedInterval > 0 {
      hotkeyMonitor.doubleTapInterval = savedInterval
    }

    hotkeyMonitor.onGesture = { [weak self] gesture in
      switch gesture {
      case .doubleControl:
        self?.perform(.read)
      case .controlOption:
        self?.perform(.summarizeAndRead)
      case .rewind:
        self?.perform(.rewind)
      case .pauseResume:
        self?.perform(.pauseResume)
      case .fastForward:
        self?.perform(.fastForward)
      case .startFromBeginning:
        self?.perform(.startFromBeginning)
      case .stop:
        self?.perform(.stop)
      }
    }
    refreshShellState()
    try? audioPlayback.warmUpStreaming(sampleRate: streamingSampleRate)
    audioPlayback.onStreamingPlaybackFinished = { [weak self] in
      self?.streamingPlaybackDidFinish()
    }

    let chatState = SummaryWindowPresenter.shared.chatState
    chatState.onSendChat = { [weak self] input, messageID in
      self?.performChatFollowUp(input, messageID: messageID)
    }
    chatState.onSpeakText = { [weak self] text in
      self?.speakText(text)
    }
    chatState.onPromptTypeChanged = { [weak self] in
      self?.summaryPromptTypeDidChange()
    }
  }

  var shellReady: Bool {
    permissions.accessibilityTrusted && hotkeysRunning
  }

  deinit {
    hotkeyMonitor.stop()
    permissionObservationTask?.cancel()
    pipelineStartWorker?.cancel()
    currentPipeline?.cancel()
    readySettleTask?.cancel()
    pauseTeardownTask?.cancel()
    voiceTask?.cancel()
    warmCartesiaTask?.cancel()
    let speechService = cartesiaRealtimeSpeech
    Task {
      await speechService.close()
    }
  }

  func perform(_ action: ReaderAction) {
    let triggeredAt = LatencyClock.now
    refreshShellState()
    cancelReadySettle()

    switch action {
    case .read:
      handleCaptureTrigger(.readClipboard, triggeredAt: triggeredAt)
    case .summarize:
      handleCaptureTrigger(.summarizeClipboard, triggeredAt: triggeredAt)
    case .summarizeAndRead:
      handleCaptureTrigger(.summarizeClipboardThenRead, triggeredAt: triggeredAt)
    case .pauseResume:
      switch audioPlayback.pauseOrResume() {
      case .resumed:
        cancelPauseTeardown()
        status = .reading
        message = "Playback resumed."
        settleBackToReadyForCurrentPlayback()
      case .paused:
        status = .paused
        message = "Playback paused. Closes after 2 minutes."
        schedulePauseTeardown()
      case .unavailable:
        message = "No active audio to pause."
      }
    case .stop:
      stopPlayback()
    case .rewind:
      let result = audioPlayback.skip(by: -10)
      message = playbackSeekMessage(result, fallback: "Rewound 10 seconds.")
      settleBackToReadyIfPlaying(result)
      refreshPauseTeardownIfPaused()
    case .fastForward:
      let result = audioPlayback.skip(by: 10)
      message = playbackSeekMessage(result, fallback: "Forwarded 10 seconds.")
      settleBackToReadyIfPlaying(result)
      refreshPauseTeardownIfPaused()
    case .startFromBeginning:
      let result = audioPlayback.startFromBeginning()
      message = playbackSeekMessage(result, fallback: "Started from the beginning.")
      settleBackToReadyIfPlaying(result)
      refreshPauseTeardownIfPaused()
    case .replay:
      replayLastAudio()
    }
  }

  func stopPlayback() {
    pendingPipelineWork = nil
    cancelReadySettle()
    cancelPauseTeardown()
    currentPipeline?.cancel()
    currentPipeline = nil
    audioPlayback.stop()
    status = .ready
    message = "Playback stopped."
  }

  func refreshShellState() {
    permissions = PermissionService.snapshot()
    providerConfiguration = ProviderConfiguration.summarize()
    refreshProviderKeyStatus()
    ensureCartesiaVoicesLoaded()

    guard permissions.accessibilityTrusted else {
      hotkeyMonitor.stop()
      hotkeysRunning = false
      status = .missingPermission
      if message == "Ready" || message == "Permissions are ready." {
        message = permissions.requiredSummary
      }
      return
    }

    if !hotkeyMonitor.isRunning {
      hotkeysRunning = hotkeyMonitor.start()
    } else {
      hotkeysRunning = hotkeyMonitor.status.ready
    }

    guard hotkeysRunning else {
      status = .missingPermission
      message = modifierListenerFailureMessage()
      return
    }

    if status == .missingPermission && shellReady {
      status = .ready
    }
    if (message.hasPrefix("Required:") || message.contains("modifier shortcut listener")) && shellReady {
      message = "Ready"
    }
    prewarmCartesiaSocket()
  }

  func requestAccessibility() {
    let outcome = PermissionService.requestAccessibilityAndGuide(appDisplayName: AIReaderAppIdentity.current().displayName)
    message = outcome.message
    refreshShellState()
    observePermissionGrant(message: outcome.message)
  }

  func openPermissionDashboardIfNeededFromMenuBar() {
    refreshShellState()
    guard !permissions.allRequiredGranted else {
      return
    }

    message = permissions.requiredSummary
    observePermissionGrant(message: message)
    showWindowAfterMenuCloses {
      SettingsWindowPresenter.shared.showPermissions(controller: self)
    }
  }

  func openPermissionDashboardWindow() {
    refreshShellState()
    showWindowAfterMenuCloses {
      SettingsWindowPresenter.shared.showPermissions(controller: self)
    }
  }

  func openPreferencesWindow() {
    refreshShellState()
    showWindowAfterMenuCloses {
      SettingsWindowPresenter.shared.showPreferences(controller: self)
    }
  }

  func openAPIKeysWindow() {
    refreshShellState()
    showWindowAfterMenuCloses {
      SettingsWindowPresenter.shared.showAPIKeys(controller: self)
    }
  }

  func openEnvFile() {
    let env = AIReaderPaths.envFileURL()
    let fallback = AIReaderPaths.envExampleURL()
    NSWorkspace.shared.open(FileManager.default.fileExists(atPath: env.path) ? env : fallback)
  }

  func setModifierTapInterval(_ interval: TimeInterval) {
    hotkeyMonitor.doubleTapInterval = interval
  }

  func saveProviderSettings(
    cartesiaAPIKey: String,
    anthropicAPIKey: String,
    cartesiaVoiceID: String,
    cartesiaModel: String,
    cartesiaLanguage: String
  ) {
    do {
      let savedVoiceID = cartesiaVoiceID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        ? ProviderConfiguration.defaultCartesiaVoiceID
        : cartesiaVoiceID
      let savedLanguage = cartesiaLanguage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        ? ProviderConfiguration.defaultCartesiaLanguage
        : cartesiaLanguage
      let savedModel = ProviderConfiguration.supportedCartesiaModel(cartesiaModel)

      var values = [
        "CARTESIA_MODEL": savedModel,
        "CARTESIA_VOICE_ID": savedVoiceID,
        "CARTESIA_LANGUAGE": savedLanguage,
        "CARTESIA_VERSION": ProviderConfiguration.defaultCartesiaVersion,
        "ANTHROPIC_MODEL": ProviderConfiguration.defaultAnthropicModel,
        "ANTHROPIC_VERSION": ProviderConfiguration.defaultAnthropicVersion,
        "ANTHROPIC_MAX_TOKENS": "\(ProviderConfiguration.defaultAnthropicMaxTokens)",
      ]
      if !cartesiaAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        values["CARTESIA_API_KEY"] = cartesiaAPIKey
      }
      if !anthropicAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        values["ANTHROPIC_API_KEY"] = anthropicAPIKey
      }

      try EnvFile.writeMerged(
        values: values,
        to: AIReaderPaths.envFileURL()
      )

      PreferenceKeys.defaults.set(savedVoiceID, forKey: PreferenceKeys.voiceSelection)
      PreferenceKeys.defaults.set(savedModel, forKey: PreferenceKeys.voiceModel)
      refreshShellState()
      message = saveMessage()
      if providerConfiguration.cartesiaConfigured {
        refreshCartesiaVoices(
          gender: savedVoiceGender(),
          language: savedLanguage
        )
      }
    } catch {
      status = .failed
      message = error.localizedDescription
    }
  }

  func ensureCartesiaVoicesLoaded(gender: VoiceGender? = nil, language: String? = nil) {
    loadCartesiaVoices(
      gender: gender ?? savedVoiceGender(),
      language: language ?? providerConfiguration.cartesiaLanguage,
      query: "",
      force: false
    )
  }

  func refreshCartesiaVoices(gender: VoiceGender?, language: String, query: String = "") {
    loadCartesiaVoices(gender: gender, language: language, query: query, force: true)
  }

  private func loadCartesiaVoices(gender: VoiceGender?, language: String, query: String, force: Bool) {
    guard providerConfiguration.cartesiaConfigured else {
      cartesiaVoices = []
      cartesiaVoiceMessage = "Add a Cartesia API key to load voices."
      lastVoiceLoadRequest = nil
      return
    }

    let loadRequest = CartesiaVoiceLoadRequest(
      gender: gender,
      language: language,
      query: query
    )

    if !force {
      if cartesiaVoicesLoading {
        return
      }
      if lastVoiceLoadRequest == loadRequest {
        return
      }
    }

    lastVoiceLoadRequest = loadRequest
    voiceTask?.cancel()
    cartesiaVoicesLoading = true
    cartesiaVoiceMessage = "Loading Cartesia voices."

    voiceTask = Task { @MainActor [weak self] in
      guard let self else { return }
      do {
        let apiKey = try ProviderConfiguration.requireCartesiaAPIKey()
        let voices = try await cartesiaVoiceService.listVoices(
          CartesiaVoiceListInput(
            apiKey: apiKey,
            language: loadRequest.language,
            gender: gender?.cartesiaValue,
            query: loadRequest.query,
            limit: 50
          )
        )
        guard !Task.isCancelled else { return }

        cartesiaVoices = voices
        cartesiaVoicesLoading = false
        refreshProviderKeyStatus(cartesiaAccepted: true)
        let selectedVoice = automaticallySelectedVoice(from: voices)
        if let selectedVoice {
          try saveCartesiaVoiceSelection(selectedVoice)
          refreshShellState()
          refreshProviderKeyStatus(cartesiaAccepted: true)
        }
        cartesiaVoiceMessage = selectedVoice.map { "Cartesia key accepted. Selected \($0.name)." }
          ?? (voices.isEmpty
          ? "Cartesia key accepted. No matching voices found."
          : "Cartesia key accepted. Loaded \(voices.count) voices.")
      } catch is CancellationError {
        return
      } catch {
        cartesiaVoicesLoading = false
        refreshProviderKeyStatus(cartesiaAccepted: false)
        cartesiaVoiceMessage = error.localizedDescription
      }
    }
  }

  func selectCartesiaVoice(_ voice: CartesiaVoice) {
    do {
      try saveCartesiaVoiceSelection(voice)
      refreshShellState()
      message = "Selected \(voice.name)."
    } catch {
      status = .failed
      message = error.localizedDescription
    }
  }

  func testCartesiaVoice() {
    let triggeredAt = LatencyClock.now
    requestPipeline { [weak self] in
      guard let self else { return }
      do {
        status = .reading
        message = "Streaming Cartesia voice test."
        let cartesia = try ProviderConfiguration.requireReadConfiguration()
        let remainingDuration = try await streamCartesiaSpeech(
          text: "AI Reader is connected to Cartesia.",
          cartesia: cartesia,
          triggeredAt: triggeredAt,
          playbackMessage: "Playing Cartesia stream test."
        )
        guard !Task.isCancelled else { return }
        settleBackToReady(from: .reading, after: remainingDuration)
      } catch is CancellationError {
        return
      } catch {
        status = .failed
        message = error.localizedDescription
        openAPIKeysWindow()
      }
    }
  }

  func testClaudeSummary() {
    let sourceText = """
      AI Reader is testing the Claude summary path. The app should send text to Anthropic, receive a concise summary, and display that summary in one reusable macOS window.
      """
    requestPipeline { [weak self] in
      guard let self else { return }
      do {
        status = .summarizing
        message = "Testing Claude summary."
        let summary = try await generateClaudeSummary(from: sourceText)
        guard !Task.isCancelled else { return }
        showSummaryWindow(summary, sourceCharacterCount: sourceText.count)
        status = .ready
        message = "Claude summary ready."
        refreshProviderKeyStatus(anthropicAccepted: true)
      } catch is CancellationError {
        return
      } catch {
        status = .failed
        message = error.localizedDescription
        refreshProviderKeyStatus(anthropicAccepted: false)
        openAPIKeysWindow()
      }
    }
  }

  private func observePermissionGrant(message: String) {
    permissionObservationTask?.cancel()
    permissionObservationTask = Task { @MainActor [weak self] in
      guard let self else { return }
      self.message = message
      for _ in 0..<120 {
        try? await Task.sleep(for: .seconds(1))
        guard !Task.isCancelled else { return }
        self.refreshShellState()
        if self.shellReady {
          self.message = "Permissions are ready."
          return
        }
      }
    }
  }

  private func readinessMessage() -> String {
    if !permissions.accessibilityTrusted {
      return permissions.requiredSummary
    }
    if !hotkeysRunning {
      return modifierListenerFailureMessage()
    }
    return "Ready"
  }

  private func modifierListenerFailureMessage() -> String {
    hotkeyMonitor.status.lastError
      ?? "The modifier shortcut listener is not active. Reopen AI Reader, then check Accessibility if it still does not start."
  }

  private func refreshProviderKeyStatus(cartesiaAccepted: Bool? = nil, anthropicAccepted: Bool? = nil) {
    cartesiaKeyStatus = ProviderKeyStatus(
      configured: providerConfiguration.cartesiaConfigured,
      accepted: cartesiaAccepted,
      maskedValue: maskedProviderSecret("CARTESIA_API_KEY")
    )
    anthropicKeyStatus = ProviderKeyStatus(
      configured: providerConfiguration.anthropicConfigured,
      accepted: anthropicAccepted,
      maskedValue: maskedProviderSecret("ANTHROPIC_API_KEY")
    )
  }

  private func savedVoiceGender() -> VoiceGender {
    VoiceGender(rawValue: PreferenceKeys.defaults.string(forKey: PreferenceKeys.voiceGender) ?? "")
      ?? .feminine
  }

  private func automaticallySelectedVoice(from voices: [CartesiaVoice]) -> CartesiaVoice? {
    guard let firstVoice = voices.first else {
      return nil
    }

    let savedVoiceID = PreferenceKeys.defaults.string(forKey: PreferenceKeys.voiceSelection)
    let configuredVoiceID = ProviderConfiguration.currentCartesiaVoiceID()
    let currentVoiceID = configuredVoiceID ?? savedVoiceID

    if let currentVoiceID, voices.contains(where: { $0.id == currentVoiceID }) {
      PreferenceKeys.defaults.set(currentVoiceID, forKey: PreferenceKeys.voiceSelection)
      return nil
    }

    return firstVoice
  }

  private func saveCartesiaVoiceSelection(_ voice: CartesiaVoice) throws {
    try EnvFile.writeMerged(
      values: [
        "CARTESIA_MODEL": ProviderConfiguration.supportedCartesiaModel(providerConfiguration.cartesiaModel),
        "CARTESIA_VOICE_ID": voice.id,
        "CARTESIA_LANGUAGE": voice.language ?? providerConfiguration.cartesiaLanguage,
        "CARTESIA_VERSION": ProviderConfiguration.defaultCartesiaVersion,
      ],
      to: AIReaderPaths.envFileURL()
    )
    PreferenceKeys.defaults.set(voice.id, forKey: PreferenceKeys.voiceSelection)
  }

  func selectCartesiaModel(_ model: CartesiaSpeechModel) {
    do {
      try EnvFile.writeMerged(
        values: ["CARTESIA_MODEL": model.rawValue],
        to: AIReaderPaths.envFileURL()
      )
      PreferenceKeys.defaults.set(model.rawValue, forKey: PreferenceKeys.voiceModel)
      lastWarmCartesiaConfiguration = nil
      refreshShellState()
      message = "Selected \(model.title)."
    } catch {
      status = .failed
      message = error.localizedDescription
    }
  }

  func selectAnthropicModel(_ model: AnthropicModel) {
    do {
      try EnvFile.writeMerged(
        values: ["ANTHROPIC_MODEL": model.rawValue],
        to: AIReaderPaths.envFileURL()
      )
      refreshShellState()
      message = "Selected \(model.title)."
    } catch {
      status = .failed
      message = error.localizedDescription
    }
  }

  private func maskedProviderSecret(_ key: String) -> String? {
    guard let envFile = try? EnvFile.load(from: AIReaderPaths.envFileURL()),
      let secret = envFile.value(for: key)
    else {
      return nil
    }

    let suffix = secret.suffix(4)
    return "•••• \(suffix)"
  }

  private func saveMessage() -> String {
    if providerConfiguration.readyForRead {
      return "Cartesia settings saved."
    }
    if providerConfiguration.cartesiaConfigured && !providerConfiguration.cartesiaVoiceConfigured {
      return "Cartesia key saved. Select a voice to finish setup."
    }
    return providerConfiguration.missingKeys.joined(separator: ", ")
  }

  private func playbackSeekMessage(
    _ result: AudioPlaybackService.SeekResult,
    fallback: String
  ) -> String {
    switch result {
    case .unavailable:
      return "No active audio to seek."
    case .moved(let snapshot):
      if snapshot.bufferedDuration > 0 {
        return "\(fallback) \(formatPlaybackTime(snapshot.playbackTime)) / \(formatPlaybackTime(snapshot.bufferedDuration))."
      }
      return fallback
    }
  }

  private func formatPlaybackTime(_ value: TimeInterval) -> String {
    let totalSeconds = max(Int(value.rounded()), 0)
    let minutes = totalSeconds / 60
    let seconds = totalSeconds % 60
    return "\(minutes):\(String(format: "%02d", seconds))"
  }

  private func showWindowAfterMenuCloses(_ show: @escaping @MainActor () -> Void) {
    Task { @MainActor in
      await Task.yield()
      show()
    }
  }

  private func startPipeline(
    _ mode: ReaderPipelineMode,
    sourceText: String,
    captureMS: Double,
    triggeredAt: UInt64
  ) {
    requestPipeline { [weak self] in
      await self?.runPipeline(mode, sourceText: sourceText, captureMS: captureMS, triggeredAt: triggeredAt)
    }
  }

  /// Single-flight pipeline coordinator. The latest request wins: rapid
  /// triggers coalesce into one start, and a new run begins only after the
  /// previous run's teardown has been awaited (bounded by the preemption
  /// grace period), so two runs never drive the socket or engine at once.
  private func requestPipeline(_ work: @escaping @MainActor () async -> Void) {
    cancelReadySettle()
    cancelPauseTeardown()
    pendingPipelineWork = work
    guard pipelineStartWorker == nil else { return }

    pipelineStartWorker = Task { @MainActor [weak self] in
      defer { self?.pipelineStartWorker = nil }
      while let next = self?.pendingPipelineWork {
        guard let self else { return }
        self.pendingPipelineWork = nil
        await self.teardownCurrentPipeline()
        guard self.pendingPipelineWork == nil else { continue }
        self.launchPipeline(next)
        return
      }
    }
  }

  private func launchPipeline(_ work: @escaping @MainActor () async -> Void) {
    pipelineEpoch += 1
    let epoch = pipelineEpoch
    currentPipeline = Task { @MainActor [weak self] in
      await work()
      guard let self, self.pipelineEpoch == epoch else { return }
      self.currentPipeline = nil
    }
  }

  private func teardownCurrentPipeline() async {
    guard let pipeline = currentPipeline else {
      audioPlayback.stop()
      return
    }
    currentPipeline = nil
    pipeline.cancel()
    audioPlayback.stop()
    await awaitPipelineCompletion(pipeline, gracePeriodMilliseconds: Self.preemptionGraceMilliseconds)
  }

  /// Waits for the superseded run to unwind so the new run can reuse the warm
  /// socket cleanly. If the old run is wedged past the grace period we proceed
  /// anyway: the Cartesia actor's cancel watchdog force-closes the socket and
  /// the next generation self-heals on a fresh connection.
  private func awaitPipelineCompletion(_ pipeline: Task<Void, Never>, gracePeriodMilliseconds: Int) async {
    await withTaskGroup(of: Void.self) { group in
      group.addTask {
        await pipeline.value
      }
      group.addTask {
        try? await Task.sleep(for: .milliseconds(gracePeriodMilliseconds))
      }
      await group.next()
      group.cancelAll()
    }
  }

  /// Captured text persists here until new selected or fallback clipboard text
  /// replaces it. Empty or unchanged capture on a spoken trigger means "hear it
  /// again": replay the banked audio rather than re-capturing and regenerating.
  private func handleCaptureTrigger(_ mode: ReaderPipelineMode, triggeredAt: UInt64) {
    let captureStart = LatencyClock.now
    var captured: CapturedText?
    var captureError: Error?
    do {
      captured = try textCapture.capture()
    } catch {
      captureError = error
    }
    let captureMS = LatencyClock.milliseconds(from: captureStart, to: LatencyClock.now)
    noteClipboardFallbackIfNeeded(captured)

    if let captured, captured.text != lastCapturedText {
      lastCapturedText = captured.text
      startPipeline(mode, sourceText: captured.text, captureMS: captureMS, triggeredAt: triggeredAt)
      return
    }

    if mode != .summarizeClipboard, currentPipeline == nil, audioPlayback.hasReplayableAudio {
      replayLastAudio()
      return
    }

    if let sourceText = captured?.text ?? lastCapturedText {
      startPipeline(mode, sourceText: sourceText, captureMS: captureMS, triggeredAt: triggeredAt)
      return
    }

    status = .missingClipboardText
    message = captureError?.localizedDescription ?? TextCaptureError.missingClipboardText.localizedDescription
  }

  private func noteClipboardFallbackIfNeeded(_ captured: CapturedText?) {
    guard captured?.source == .clipboard,
      let selectionFailure = captured?.directSelectionFailure
    else {
      return
    }

    let fallbackMessage =
      "Using copied text because selected-text capture failed: \(selectionFailure.localizedDescription)"
    message = fallbackMessage
    latencyMessage = fallbackMessage
  }

  private func replayLastAudio() {
    requestPipeline { [weak self] in
      guard let self else { return }
      do {
        status = .reading
        message = "Replaying last audio."
        let duration = try audioPlayback.replay()
        guard !Task.isCancelled else { return }
        settleBackToReady(from: .reading, after: duration)
      } catch is CancellationError {
        return
      } catch {
        status = .failed
        message = error.localizedDescription
      }
    }
  }

  func speakText(_ text: String) {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    let triggeredAt = LatencyClock.now
    requestPipeline { [weak self] in
      guard let self else { return }
      do {
        let cartesia = try ProviderConfiguration.requireReadConfiguration()
        status = .reading
        message = "Reading reply aloud."
        let remainingDuration = try await streamCartesiaTextBySegments(
          text: trimmed,
          cartesia: cartesia,
          triggeredAt: triggeredAt,
          captureMS: 0,
          playbackMessage: "Reading reply aloud."
        )
        guard !Task.isCancelled else { return }
        settleBackToReady(from: .reading, after: remainingDuration)
      } catch is CancellationError {
        return
      } catch ProviderConfigurationError.missingKeys(let keys) {
        status = .failed
        message = "Missing provider keys: \(keys.joined(separator: ", "))."
        openAPIKeysWindow()
      } catch {
        status = .failed
        message = await userFacingProviderErrorMessage(error)
      }
    }
  }

  func performChatFollowUp(_ input: AnthropicChatInput, messageID: SummaryChatMessage.ID) {
    let triggeredAt = LatencyClock.now
    requestPipeline { [weak self] in
      guard let self else { return }
      let chatState = SummaryWindowPresenter.shared.chatState
      do {
        status = .summarizing
        message = "Streaming Claude reply into voice."
        let remainingDuration = try await streamClaudeToSpeech(
          input,
          speak: true,
          triggeredAt: triggeredAt,
          initialTiming: SummaryPipelineTiming(captureMS: 0, windowMS: nil),
          playbackMessage: "Reading Claude reply.",
          onDelta: { chatState.appendStreamingDelta(to: messageID, $0) },
          onFinish: { text, statusText in
            chatState.finishStreamingMessage(
              id: messageID,
              text: text,
              statusText: statusText,
              asSummaryContext: false
            )
          }
        )
        guard !Task.isCancelled else { return }
        settleBackToReady(from: .reading, after: remainingDuration ?? 0.9)
      } catch is CancellationError {
        chatState.failStreamingMessage(id: messageID, statusText: "Reply stopped.")
        return
      } catch {
        let failure = await userFacingProviderErrorMessage(error)
        chatState.failStreamingMessage(id: messageID, statusText: failure)
        status = .failed
        message = failure
      }
    }
  }

  /// Switching the summary style regenerates the remembered captured text
  /// with the new prompt and appends the result to the chat.
  func summaryPromptTypeDidChange() {
    let chatState = SummaryWindowPresenter.shared.chatState
    guard let sourceText = lastCapturedText, chatState.hasSummaryContent else { return }
    let speak = lastSummaryWasSpoken
    let triggeredAt = LatencyClock.now
    requestPipeline { [weak self] in
      guard let self else { return }
      do {
        status = .summarizing
        message = "Restyling summary."
        let remainingDuration = try await streamRestyledSummary(
          from: sourceText,
          speak: speak,
          triggeredAt: triggeredAt
        )
        guard !Task.isCancelled else { return }
        if speak {
          settleBackToReady(from: .reading, after: remainingDuration ?? 0.9)
        } else {
          status = .ready
          message = "Summary restyled."
        }
      } catch is CancellationError {
        return
      } catch {
        status = .failed
        message = await userFacingProviderErrorMessage(error)
      }
    }
  }

  private func streamRestyledSummary(
    from sourceText: String,
    speak: Bool,
    triggeredAt: UInt64
  ) async throws -> TimeInterval? {
    let anthropic = try ProviderConfiguration.requireAnthropicConfiguration()
    let typeID = selectedSummaryTypeID()
    let prompt = SummaryPrompt.load(typeID: typeID)
    let styleTitle = SummaryPrompt.prettyTitle(typeID)
    let chatState = SummaryWindowPresenter.shared.chatState
    let messageID = chatState.beginStreamingAssistantMessage(marker: "Restyled as \(styleTitle).")
    SummaryWindowPresenter.shared.showWindowIfNeeded()

    let input = AnthropicChatInput(
      configuration: anthropic,
      systemPrompt: prompt,
      messages: [AnthropicChatMessage(role: .user, content: sourceText)]
    )

    do {
      return try await streamClaudeToSpeech(
        input,
        speak: speak,
        triggeredAt: triggeredAt,
        initialTiming: SummaryPipelineTiming(captureMS: 0, windowMS: nil),
        playbackMessage: "Reading restyled summary.",
        onDelta: { chatState.appendStreamingDelta(to: messageID, $0) },
        onFinish: { text, statusText in
          chatState.finishStreamingMessage(
            id: messageID,
            text: text,
            statusText: statusText,
            asSummaryContext: true
          )
        }
      )
    } catch {
      chatState.failStreamingMessage(id: messageID, statusText: error.localizedDescription)
      throw error
    }
  }

  private func schedulePauseTeardown() {
    pauseTeardownTask?.cancel()
    pauseTeardownTask = Task { @MainActor [weak self] in
      do {
        try await Task.sleep(for: .seconds(Self.pauseTeardownSeconds))
      } catch {
        return
      }
      guard !Task.isCancelled, let self else { return }
      self.pauseTeardownTask = nil
      await self.closePausedDictation()
    }
  }

  private func cancelPauseTeardown() {
    pauseTeardownTask?.cancel()
    pauseTeardownTask = nil
  }

  private func refreshPauseTeardownIfPaused() {
    guard status == .paused else { return }
    schedulePauseTeardown()
  }

  /// Users treat pause as stop: after a dictation sits paused for two
  /// minutes, tear the run down fully (Claude stream, TTS context, queued
  /// buffers) but bank the audio first so Ctrl+Option can still replay it.
  private func closePausedDictation() async {
    guard status == .paused else { return }
    pendingPipelineWork = nil
    cancelReadySettle()
    if let pipeline = currentPipeline {
      currentPipeline = nil
      pipeline.cancel()
      await awaitPipelineCompletion(pipeline, gracePeriodMilliseconds: Self.preemptionGraceMilliseconds)
    }
    audioPlayback.finishStreaming()
    audioPlayback.stop()
    guard status == .paused else { return }
    status = .ready
    message = "Paused dictation closed. Press Ctrl+Option to replay it."
  }

  private func runPipeline(
    _ mode: ReaderPipelineMode,
    sourceText: String,
    captureMS: Double,
    triggeredAt: UInt64
  ) async {
    do {
      switch mode {
      case .readClipboard:
        status = .reading
        message = "Streaming captured text into Cartesia."
        let cartesia = try ProviderConfiguration.requireReadConfiguration()
        let remainingDuration = try await streamCartesiaTextBySegments(
          text: sourceText,
          cartesia: cartesia,
          triggeredAt: triggeredAt,
          captureMS: captureMS,
          playbackMessage: "Reading captured text."
        )
        guard !Task.isCancelled else { return }
        settleBackToReady(from: .reading, after: remainingDuration)

      case .summarizeClipboard:
        lastSummaryWasSpoken = false
        status = .summarizing
        message = "Streaming captured text to Claude."
        _ = try await streamClaudeSummary(
          from: sourceText,
          sourceCharacterCount: sourceText.count,
          triggeredAt: triggeredAt,
          captureMS: captureMS,
          speak: false
        )
        guard !Task.isCancelled else { return }
        status = .ready
        message = "Claude summary ready."
        refreshProviderKeyStatus(anthropicAccepted: true)

      case .summarizeClipboardThenRead:
        lastSummaryWasSpoken = true
        status = .summarizing
        message = "Streaming Claude summary into voice."
        let remainingDuration = try await streamClaudeSummary(
          from: sourceText,
          sourceCharacterCount: sourceText.count,
          triggeredAt: triggeredAt,
          captureMS: captureMS,
          speak: true
        )
        guard !Task.isCancelled else { return }
        settleBackToReady(from: .reading, after: remainingDuration ?? 0.9)
      }
    } catch ProviderConfigurationError.missingKeys(let keys) {
      status = .failed
      message = "Missing provider keys: \(keys.joined(separator: ", "))."
      openAPIKeysWindow()
    } catch is CancellationError {
      return
    } catch {
      status = .failed
      message = await userFacingProviderErrorMessage(error)
    }
  }

  /// The summary style currently selected in the menu / summary window. Read live
  /// from defaults so the choice — and, via `load(typeID:)`, the prompt file's
  /// current contents — is always picked up on the next Claude generation.
  private func selectedSummaryTypeID() -> String {
    PreferenceKeys.currentSummaryPromptTypeID()
  }

  private func generateClaudeSummary(from sourceText: String) async throws -> String {
    let anthropic = try ProviderConfiguration.requireAnthropicConfiguration()
    let prompt = SummaryPrompt.load(typeID: selectedSummaryTypeID())
    return try await anthropicSummary.summarize(
      AnthropicSummaryInput(configuration: anthropic, prompt: prompt, sourceText: sourceText)
    )
  }

  private func streamClaudeSummary(
    from sourceText: String,
    sourceCharacterCount: Int,
    triggeredAt: UInt64,
    captureMS: Double,
    speak: Bool
  ) async throws -> TimeInterval? {
    let anthropic = try ProviderConfiguration.requireAnthropicConfiguration()
    let prompt = SummaryPrompt.load(typeID: selectedSummaryTypeID())
    let windowStart = LatencyClock.now
    let summaryInput = SummaryWindowPresenter.shared.startSummaryRequest(
      configuration: anthropic,
      systemPrompt: prompt,
      sourceText: sourceText,
      sourceCharacterCount: sourceCharacterCount,
      statusText: "Starting Claude stream."
    )
    let windowMS = LatencyClock.milliseconds(from: windowStart, to: LatencyClock.now)

    let cartesiaAvailable = (try? ProviderConfiguration.requireReadConfiguration()) != nil
    let remainingDuration = try await streamClaudeToSpeech(
      summaryInput,
      speak: speak && cartesiaAvailable,
      triggeredAt: triggeredAt,
      initialTiming: SummaryPipelineTiming(captureMS: captureMS, windowMS: windowMS),
      playbackMessage: "Reading Claude summary.",
      onDelta: { SummaryWindowPresenter.shared.appendSummaryDelta($0) },
      onFinish: { text, statusText in
        SummaryWindowPresenter.shared.finishSummary(text, statusText: statusText)
      }
    )

    if speak, !cartesiaAvailable {
      throw ProviderConfigurationError.missingKeys(["CARTESIA_API_KEY", "CARTESIA_VOICE_ID"])
    }
    return remainingDuration
  }

  /// Streams one Claude response into the summary window (via the supplied
  /// sinks) and, when speaking, into Cartesia as sentences complete.
  private func streamClaudeToSpeech(
    _ input: AnthropicChatInput,
    speak: Bool,
    triggeredAt: UInt64,
    initialTiming: SummaryPipelineTiming,
    playbackMessage: String,
    onDelta: @escaping (String) -> Void,
    onFinish: @escaping (String, String) -> Void
  ) async throws -> TimeInterval? {
    var timing = initialTiming
    timing.claudeRequestMS = LatencyClock.milliseconds(from: triggeredAt, to: LatencyClock.now)
    updateSummaryTiming(timing)

    guard speak, let cartesia = try? ProviderConfiguration.requireReadConfiguration() else {
      _ = try await consumeClaudeStream(
        input,
        triggeredAt: triggeredAt,
        timing: &timing,
        emitSegment: nil,
        onDelta: onDelta,
        onFinish: onFinish
      )
      return nil
    }

    status = .reading
    let bridge = TextSegmentStreamBridge()
    let speechTiming = timing
    // Structured child: started eagerly so the Cartesia handshake overlaps
    // Claude's time to first token, and cancelled+awaited automatically if
    // this scope exits early.
    async let remainingDuration: TimeInterval = streamCartesiaSpeechSegments(
      textSegments: bridge.stream,
      cartesia: cartesia,
      triggeredAt: triggeredAt,
      timing: speechTiming,
      playbackMessage: playbackMessage
    )

    do {
      _ = try await consumeClaudeStream(
        input,
        triggeredAt: triggeredAt,
        timing: &timing,
        emitSegment: { bridge.yield($0) },
        onDelta: onDelta,
        onFinish: onFinish
      )
      bridge.finish()
    } catch {
      bridge.finish(throwing: error)
      throw error
    }

    return try await remainingDuration
  }

  private func consumeClaudeStream(
    _ summaryInput: AnthropicChatInput,
    triggeredAt: UInt64,
    timing: inout SummaryPipelineTiming,
    emitSegment: ((String) -> Void)?,
    onDelta: (String) -> Void,
    onFinish: (String, String) -> Void
  ) async throws -> String {
    var summary = ""
    var speechChunker = StreamingSpeechChunker()
    let stream = anthropicSummary.stream(summaryInput)

    for try await event in stream {
      try Task.checkCancellation()
      switch event {
      case .responseStarted:
        timing.claudeResponseMS = LatencyClock.milliseconds(from: triggeredAt, to: LatencyClock.now)
        updateSummaryTiming(timing)

      case .textDelta(let delta):
        if timing.claudeFirstTextMS == nil {
          timing.claudeFirstTextMS = LatencyClock.milliseconds(from: triggeredAt, to: LatencyClock.now)
        }
        summary += delta
        onDelta(delta)
        if let emitSegment {
          for segment in speechChunker.append(delta) {
            emitSegment(segment)
          }
        }
        updateSummaryTiming(timing)

      case .messageStop:
        break
      }
    }

    if let emitSegment {
      for segment in speechChunker.finish() {
        emitSegment(segment)
      }
    }

    guard !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw ProviderAPIError.emptyResponse(provider: "Anthropic")
    }

    timing.claudeDoneMS = LatencyClock.milliseconds(from: triggeredAt, to: LatencyClock.now)
    onFinish(summary, timing.summary)
    latencyMessage = timing.summary
    refreshProviderKeyStatus(anthropicAccepted: true)
    return summary
  }

  private func showSummaryWindow(_ summary: String, sourceCharacterCount: Int) {
    SummaryWindowPresenter.shared.show(summary: summary, sourceCharacterCount: sourceCharacterCount)
  }

  private func currentVolumeMultiplier() -> Double {
    let savedVolume = PreferenceKeys.defaults.double(forKey: PreferenceKeys.volumeMultiplier)
    return savedVolume > 0 ? savedVolume : 1
  }

  private func prewarmCartesiaSocket() {
    guard providerConfiguration.readyForRead,
      let cartesia = try? ProviderConfiguration.requireReadConfiguration()
    else {
      return
    }

    guard cartesia != lastWarmCartesiaConfiguration else {
      return
    }

    lastWarmCartesiaConfiguration = cartesia
    warmCartesiaTask?.cancel()
    let service = cartesiaRealtimeSpeech
    warmCartesiaTask = Task { [weak self, service, cartesia] in
      do {
        try await service.warmUp(configuration: cartesia)
        guard !Task.isCancelled else { return }
        await MainActor.run {
          if self?.latencyMessage == "Latency not measured yet." {
            self?.latencyMessage = "Cartesia WebSocket warmed."
          }
        }
      } catch is CancellationError {
        return
      } catch {
        await MainActor.run {
          self?.lastWarmCartesiaConfiguration = nil
        }
        let message = await self?.userFacingProviderErrorMessage(error, cartesia: cartesia)
          ?? error.localizedDescription
        await MainActor.run {
          self?.latencyMessage = "Cartesia WebSocket warm-up failed: \(message)"
        }
      }
    }
  }

  private func userFacingProviderErrorMessage(
    _ error: Error,
    cartesia providedCartesia: CartesiaConfiguration? = nil
  ) async -> String {
    guard Self.isBadServerResponse(error) else {
      return error.localizedDescription
    }

    guard let cartesia = providedCartesia ?? (try? ProviderConfiguration.requireReadConfiguration()) else {
      return error.localizedDescription
    }

    do {
      _ = try await cartesiaDiagnosticSpeech.synthesize(
        CartesiaSpeechInput(
          configuration: cartesia,
          text: "AI Reader Cartesia diagnostics.",
          volume: 0.5
        )
      )
      return "Cartesia WebSocket handshake failed, but the HTTPS Cartesia diagnostic succeeded. Retry, or reopen AI Reader to force a fresh socket."
    } catch {
      if let message = Self.providerHTTPErrorMessage(error) {
        return message
      }
      return "Cartesia WebSocket handshake failed. Cartesia HTTPS diagnostic also failed: \(error.localizedDescription)"
    }
  }

  private static func isBadServerResponse(_ error: Error) -> Bool {
    let nsError = error as NSError
    return nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorBadServerResponse
  }

  private static func providerHTTPErrorMessage(_ error: Error) -> String? {
    guard case let ProviderAPIError.httpError(provider, statusCode, body) = error else {
      return nil
    }

    let payload = try? JSONDecoder().decode(
      ProviderHTTPErrorPayload.self,
      from: Data(body.utf8)
    )
    let title = payload?.title ?? "\(provider) HTTP \(statusCode)"
    let message = payload?.message ?? body
    let code = payload?.errorCode.map { " (\($0), HTTP \(statusCode))" } ?? " (HTTP \(statusCode))"
    return "\(title): \(message)\(code)"
  }

  private func streamCartesiaSpeech(
    text: String,
    cartesia: CartesiaConfiguration,
    triggeredAt: UInt64,
    playbackMessage: String
  ) async throws -> TimeInterval {
    try audioPlayback.prepareForStreaming(sampleRate: streamingSampleRate)
    let audioPreparedMS = LatencyClock.milliseconds(from: triggeredAt, to: LatencyClock.now)

    let input = CartesiaStreamingSpeechInput(
      configuration: cartesia,
      text: text,
      volume: currentVolumeMultiplier(),
      sampleRate: streamingSampleRate
    )

    var reusedConnection = false
    var requestSentMS: Double?
    var firstChunkMS: Double?
    var firstScheduledMS: Double?
    var firstScheduledAt: UInt64?
    var firstStepTimeMS: Int?
    var chunkCount = 0
    var byteCount = 0

    for try await event in cartesiaRealtimeSpeech.events(for: input) {
      try Task.checkCancellation()

      switch event {
      case .connected(let reused):
        reusedConnection = reused
        message = reused ? "Using warm Cartesia WebSocket." : "Opening Cartesia WebSocket."

      case .requestSent:
        requestSentMS = LatencyClock.milliseconds(from: triggeredAt, to: LatencyClock.now)
        message = "Waiting for first Cartesia audio chunk."

      case .audioChunk(let chunk):
        chunkCount += 1
        byteCount += chunk.data.count
        if firstChunkMS == nil {
          firstChunkMS = LatencyClock.milliseconds(from: triggeredAt, to: LatencyClock.now)
          firstStepTimeMS = chunk.stepTimeMS
        }

        _ = try audioPlayback.enqueuePCMFloat32(chunk.data, sampleRate: streamingSampleRate)

        if firstScheduledMS == nil {
          let scheduledAt = LatencyClock.now
          firstScheduledAt = scheduledAt
          firstScheduledMS = LatencyClock.milliseconds(from: triggeredAt, to: scheduledAt)
          latencyMessage = latencyReport(
            audioPreparedMS: audioPreparedMS,
            requestSentMS: requestSentMS,
            firstChunkMS: firstChunkMS,
            firstScheduledMS: firstScheduledMS,
            cartesiaStepTimeMS: firstStepTimeMS,
            chunkCount: chunkCount,
            byteCount: byteCount,
            reusedConnection: reusedConnection
          )
          message = playbackMessage
        }

      case .done:
        break
      }
    }

    let totalDuration = audioPlayback.finishStreaming()
    guard let firstScheduledAt else {
      throw ProviderAPIError.emptyResponse(provider: "Cartesia")
    }

    latencyMessage = latencyReport(
      audioPreparedMS: audioPreparedMS,
      requestSentMS: requestSentMS,
      firstChunkMS: firstChunkMS,
      firstScheduledMS: firstScheduledMS,
      cartesiaStepTimeMS: firstStepTimeMS,
      chunkCount: chunkCount,
      byteCount: byteCount,
      reusedConnection: reusedConnection
    )

    let elapsedSinceFirstAudio = LatencyClock.seconds(from: firstScheduledAt, to: LatencyClock.now)
    return max(totalDuration - elapsedSinceFirstAudio, 0.2)
  }

  private func streamCartesiaTextBySegments(
    text: String,
    cartesia: CartesiaConfiguration,
    triggeredAt: UInt64,
    captureMS: Double,
    playbackMessage: String
  ) async throws -> TimeInterval {
    let bridge = TextSegmentStreamBridge()
    let timing = SummaryPipelineTiming(captureMS: captureMS, windowMS: nil)
    // Structured child: cancelled+awaited automatically if this scope exits.
    async let remainingDuration: TimeInterval = streamCartesiaSpeechSegments(
      textSegments: bridge.stream,
      cartesia: cartesia,
      triggeredAt: triggeredAt,
      timing: timing,
      playbackMessage: playbackMessage
    )

    var chunker = StreamingSpeechChunker()
    for segment in chunker.append(text) {
      bridge.yield(segment)
    }
    for segment in chunker.finish() {
      bridge.yield(segment)
    }
    bridge.finish()

    return try await remainingDuration
  }

  private func streamCartesiaSpeechSegments(
    textSegments: AsyncThrowingStream<String, Error>,
    cartesia: CartesiaConfiguration,
    triggeredAt: UInt64,
    timing initialTiming: SummaryPipelineTiming,
    playbackMessage: String = "Reading Claude summary."
  ) async throws -> TimeInterval {
    var timing = initialTiming
    try audioPlayback.prepareForStreaming(sampleRate: streamingSampleRate)
    timing.audioPreparedMS = LatencyClock.milliseconds(from: triggeredAt, to: LatencyClock.now)

    let input = CartesiaStreamingSpeechInput(
      configuration: cartesia,
      text: "",
      volume: currentVolumeMultiplier(),
      sampleRate: streamingSampleRate
    )

    var firstScheduledAt: UInt64?

    for try await event in cartesiaRealtimeSpeech.events(for: input, textSegments: textSegments) {
      try Task.checkCancellation()

      switch event {
      case .connected(let reused):
        timing.reusedCartesiaConnection = reused
        message = reused ? "Using warm Cartesia WebSocket." : "Opening Cartesia WebSocket."
        updateSummaryTiming(timing)

      case .requestSent:
        if timing.cartesiaRequestMS == nil {
          timing.cartesiaRequestMS = LatencyClock.milliseconds(from: triggeredAt, to: LatencyClock.now)
        }
        message = "Waiting for first Cartesia audio chunk."
        updateSummaryTiming(timing)

      case .audioChunk(let chunk):
        timing.chunkCount += 1
        timing.byteCount += chunk.data.count
        if timing.cartesiaFirstChunkMS == nil {
          timing.cartesiaFirstChunkMS = LatencyClock.milliseconds(from: triggeredAt, to: LatencyClock.now)
          timing.cartesiaStepTimeMS = chunk.stepTimeMS
        }

        _ = try audioPlayback.enqueuePCMFloat32(chunk.data, sampleRate: streamingSampleRate)

        if timing.cartesiaFirstAudioMS == nil {
          let scheduledAt = LatencyClock.now
          firstScheduledAt = scheduledAt
          timing.cartesiaFirstAudioMS = LatencyClock.milliseconds(from: triggeredAt, to: scheduledAt)
          message = playbackMessage
        }
        updateSummaryTiming(timing)

      case .done:
        break
      }
    }

    let totalDuration = audioPlayback.finishStreaming()
    guard let firstScheduledAt else {
      throw ProviderAPIError.emptyResponse(provider: "Cartesia")
    }

    updateSummaryTiming(timing)
    let elapsedSinceFirstAudio = LatencyClock.seconds(from: firstScheduledAt, to: LatencyClock.now)
    return max(totalDuration - elapsedSinceFirstAudio, 0.2)
  }

  private func updateSummaryTiming(_ timing: SummaryPipelineTiming) {
    let summary = timing.summary
    latencyMessage = summary
    SummaryWindowPresenter.shared.updateStatus(summary)
  }

  private func latencyReport(
    audioPreparedMS: Double,
    requestSentMS: Double?,
    firstChunkMS: Double?,
    firstScheduledMS: Double?,
    cartesiaStepTimeMS: Int?,
    chunkCount: Int,
    byteCount: Int,
    reusedConnection: Bool
  ) -> String {
    guard let firstScheduledMS else {
      return "Latency pending."
    }

    let targetStatus = firstScheduledMS <= targetFirstAudioMS ? "hit" : "miss"
    let requestText = requestSentMS.map { "\(LatencyClock.format($0))ms send" } ?? "send pending"
    let chunkText = firstChunkMS.map { "\(LatencyClock.format($0))ms first chunk" } ?? "chunk pending"
    let stepText = cartesiaStepTimeMS.map { ", Cartesia step \($0)ms" } ?? ""
    let connectionText = reusedConnection ? "warm" : "cold"
    let kilobytes = Double(byteCount) / 1024.0
    return "First audio \(LatencyClock.format(firstScheduledMS))ms (\(targetStatus) 50ms, \(connectionText)); \(requestText), \(chunkText), local prep \(LatencyClock.format(audioPreparedMS))ms\(stepText), \(chunkCount) chunks/\(LatencyClock.format(kilobytes))KB."
  }

  /// Safety-net fallback only. The primary "playback finished" signal is
  /// `streamingPlaybackDidFinish()`, driven by real buffer completion; this
  /// timer pads generously so status can never stay stuck on `.reading` if
  /// that event is somehow missed.
  private func settleBackToReady(from expectedStatus: ReaderStatus, after delay: TimeInterval = 0.9) {
    cancelReadySettle()
    readySettleTask = Task { @MainActor [weak self] in
      let clampedDelay = min(max(delay + 5, 5), 600)
      do {
        try await Task.sleep(for: .milliseconds(Int(clampedDelay * 1000)))
      } catch {
        return
      }
      guard !Task.isCancelled, let self else { return }
      readySettleTask = nil
      guard status == expectedStatus else { return }
      status = .ready
      message = "Ready"
    }
  }

  private func streamingPlaybackDidFinish() {
    guard status == .reading else { return }
    cancelReadySettle()
    status = .ready
    message = "Ready"
  }

  private func cancelReadySettle() {
    readySettleTask?.cancel()
    readySettleTask = nil
  }

  private func settleBackToReadyIfPlaying(_ result: AudioPlaybackService.SeekResult) {
    guard case .moved(let snapshot) = result, snapshot.isPlaying else {
      return
    }
    settleBackToReady(from: .reading, after: remainingPlaybackDuration(snapshot))
  }

  private func settleBackToReadyForCurrentPlayback() {
    let snapshot = audioPlayback.playbackSnapshot
    guard snapshot.isPlaying else {
      return
    }
    settleBackToReady(from: .reading, after: remainingPlaybackDuration(snapshot))
  }

  private func remainingPlaybackDuration(_ snapshot: AudioPlaybackService.PlaybackSnapshot) -> TimeInterval {
    max(snapshot.bufferedDuration - snapshot.playbackTime, 0.2)
  }
}

struct ProviderKeyStatus: Equatable {
  var configured: Bool
  var accepted: Bool?
  var maskedValue: String?

  static let missing = ProviderKeyStatus(configured: false, accepted: nil, maskedValue: nil)

  var title: String {
    guard configured else {
      return "Missing"
    }
    if accepted == true {
      return "Accepted"
    }
    if accepted == false {
      return "Rejected"
    }
    return "Saved"
  }

  var displayValue: String {
    guard configured else {
      return "Missing"
    }
    return maskedValue ?? "Saved"
  }

  var systemImage: String {
    guard configured else {
      return "exclamationmark.circle"
    }
    if accepted == true {
      return "checkmark.circle.fill"
    }
    if accepted == false {
      return "xmark.circle.fill"
    }
    return "checkmark.circle"
  }
}

private enum ReaderPipelineMode {
  case readClipboard
  case summarizeClipboard
  case summarizeClipboardThenRead
}

private struct CartesiaVoiceLoadRequest: Equatable {
  var gender: VoiceGender?
  var language: String
  var query: String
}

private struct ProviderHTTPErrorPayload: Decodable {
  var errorCode: String?
  var message: String?
  var title: String?

  enum CodingKeys: String, CodingKey {
    case errorCode = "error_code"
    case message
    case title
  }
}

private struct SummaryPipelineTiming: Equatable {
  var captureMS: Double
  var windowMS: Double?
  var claudeRequestMS: Double?
  var claudeResponseMS: Double?
  var claudeFirstTextMS: Double?
  var claudeDoneMS: Double?
  var audioPreparedMS: Double?
  var cartesiaRequestMS: Double?
  var cartesiaFirstChunkMS: Double?
  var cartesiaFirstAudioMS: Double?
  var cartesiaStepTimeMS: Int?
  var chunkCount = 0
  var byteCount = 0
  var reusedCartesiaConnection = false

  var summary: String {
    var parts = [
      "capture \(LatencyClock.format(captureMS))ms",
    ]
    if let windowMS {
      parts.append("window \(LatencyClock.format(windowMS))ms")
    }
    if let claudeResponseMS {
      parts.append("Claude headers \(LatencyClock.format(claudeResponseMS))ms")
    } else if let claudeRequestMS {
      parts.append("Claude sent \(LatencyClock.format(claudeRequestMS))ms")
    }
    if let claudeFirstTextMS {
      parts.append("first text \(LatencyClock.format(claudeFirstTextMS))ms")
    }
    if let claudeDoneMS {
      parts.append("Claude done \(LatencyClock.format(claudeDoneMS))ms")
    }
    if let audioPreparedMS {
      parts.append("audio prep \(LatencyClock.format(audioPreparedMS))ms")
    }
    if let cartesiaRequestMS {
      parts.append("Cartesia sent \(LatencyClock.format(cartesiaRequestMS))ms")
    }
    if let cartesiaFirstChunkMS {
      parts.append("first chunk \(LatencyClock.format(cartesiaFirstChunkMS))ms")
    }
    if let cartesiaFirstAudioMS {
      parts.append("first audio \(LatencyClock.format(cartesiaFirstAudioMS))ms")
    }
    if let cartesiaStepTimeMS {
      parts.append("Cartesia step \(cartesiaStepTimeMS)ms")
    }
    if chunkCount > 0 {
      let kilobytes = Double(byteCount) / 1024.0
      let connectionText = reusedCartesiaConnection ? "warm" : "cold"
      parts.append("\(connectionText), \(chunkCount) chunks/\(LatencyClock.format(kilobytes))KB")
    }
    return parts.joined(separator: " | ")
  }
}

struct TextSegmentStreamBridge: Sendable {
  let stream: AsyncThrowingStream<String, Error>
  private let continuation: AsyncThrowingStream<String, Error>.Continuation

  init() {
    var capturedContinuation: AsyncThrowingStream<String, Error>.Continuation?
    stream = AsyncThrowingStream { continuation in
      capturedContinuation = continuation
    }
    continuation = capturedContinuation!
  }

  func yield(_ segment: String) {
    continuation.yield(segment)
  }

  func finish() {
    continuation.finish()
  }

  func finish(throwing error: Error) {
    continuation.finish(throwing: error)
  }
}

struct StreamingSpeechChunker {
  private var buffer = ""
  private let punctuationCharacters = CharacterSet(charactersIn: ".!?\n")
  private let minimumPunctuationLength = 40
  private let forcedChunkLength = 180
  private let minimumForcedLength = 90

  mutating func append(_ delta: String) -> [String] {
    buffer += delta
    return drain(final: false)
  }

  mutating func finish() -> [String] {
    drain(final: true)
  }

  private mutating func drain(final: Bool) -> [String] {
    var segments: [String] = []

    while let boundary = punctuationBoundary(), distanceThrough(boundary) >= minimumPunctuationLength {
      let end = buffer.index(after: boundary)
      appendCleaned(String(buffer[..<end]), to: &segments)
      buffer.removeSubrange(..<end)
    }

    while buffer.count >= forcedChunkLength, let boundary = forcedBoundary() {
      let end = buffer.index(after: boundary)
      appendCleaned(String(buffer[..<end]), to: &segments)
      buffer.removeSubrange(..<end)
    }

    if final {
      appendCleaned(buffer, to: &segments)
      buffer = ""
    }

    return segments
  }

  private func punctuationBoundary() -> String.Index? {
    buffer.indices.first { index in
      guard distanceThrough(index) >= minimumPunctuationLength else {
        return false
      }
      let scalarView = String(buffer[index]).unicodeScalars
      return scalarView.contains { punctuationCharacters.contains($0) }
    }
  }

  private func forcedBoundary() -> String.Index? {
    let limit = buffer.index(buffer.startIndex, offsetBy: min(forcedChunkLength, buffer.count) - 1)
    let candidates = buffer[buffer.startIndex...limit].indices.reversed()
    return candidates.first { index in
      buffer.distance(from: buffer.startIndex, to: index) >= minimumForcedLength
        && buffer[index].isWhitespace
    } ?? limit
  }

  private func distanceThrough(_ index: String.Index) -> Int {
    buffer.distance(from: buffer.startIndex, to: index) + 1
  }

  private func appendCleaned(_ rawSegment: String, to segments: inout [String]) {
    let segment = rawSegment.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !segment.isEmpty else { return }
    segments.append(segment)
  }
}

private enum LatencyClock {
  static var now: UInt64 {
    DispatchTime.now().uptimeNanoseconds
  }

  static func milliseconds(from start: UInt64, to end: UInt64) -> Double {
    Double(end - start) / 1_000_000
  }

  static func seconds(from start: UInt64, to end: UInt64) -> TimeInterval {
    Double(end - start) / 1_000_000_000
  }

  static func format(_ value: Double) -> String {
    if value >= 100 {
      return "\(Int(value.rounded()))"
    }
    return String(format: "%.1f", value)
  }
}
