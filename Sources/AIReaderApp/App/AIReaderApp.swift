import AIReaderCore
import AppKit
import Foundation
import SwiftUI

@main
struct AIReaderApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
  @StateObject private var controller = ReaderController()

  init() {
    if CommandLine.arguments.contains("--request-accessibility") {
      NSApplication.shared.setActivationPolicy(.regular)
      NSApplication.shared.activate(ignoringOtherApps: true)
      let granted = PermissionService.requestAccessibility()
      print("accessibility_granted=\(granted)")
      exit(granted ? EXIT_SUCCESS : EXIT_FAILURE)
    }

    if CommandLine.arguments.contains("--shortcut-probe") {
      Self.runShortcutProbe()
    }

    if CommandLine.arguments.contains("--clipboard-probe") {
      Self.runClipboardProbe()
    }

    if let sourceText = Self.claudeSummaryProbeText(from: CommandLine.arguments) {
      Self.runClaudeSummaryProbe(sourceText: sourceText)
    }

    if let sourceText = Self.chainedSummaryTTSProbeText(from: CommandLine.arguments) {
      Self.runChainedSummaryTTSProbe(sourceText: sourceText)
    }

    if CommandLine.arguments.contains("--playback-seek-probe") {
      Self.runPlaybackSeekProbe()
    }

    if CommandLine.arguments.contains("--tts-probe") {
      Self.runTTSProbe()
    }

    if CommandLine.arguments.contains("--launch-at-login-probe")
      || CommandLine.arguments.contains("--launch-at-login-register-probe")
      || CommandLine.arguments.contains("--launch-at-login-unregister-probe") {
      Self.runLaunchAtLoginProbe()
    }
  }

  var body: some Scene {
    MenuBarExtra {
      MenuBarView()
        .environmentObject(controller)
    } label: {
      Label(controller.status.title, systemImage: controller.status.systemImage)
    }
    .menuBarExtraStyle(.menu)
  }

  private static func runShortcutProbe() -> Never {
    let monitor = ModifierTapHotkeyMonitor()
    var sawDoubleControl = false
    var sawControlOption = false
    var sawControlA = false
    var sawControlS = false
    var sawControlD = false
    var sawControlB = false

    print("shortcut_probe_ready=1")
    print("press=double_control action=read")
    print("press=control_option action=summarize_and_read")
    print("press=control_a action=rewind")
    print("press=control_s action=pause_resume")
    print("press=control_d action=fast_forward")
    print("press=control_b action=stop")
    fflush(stdout)

    monitor.playbackKeyGesturesEnabled = true
    monitor.onGesture = { gesture in
      switch gesture {
      case .doubleControl:
        sawDoubleControl = true
        print("gesture=double_control action=read")
      case .controlOption:
        sawControlOption = true
        print("gesture=control_option action=summarize_and_read")
      case .rewind:
        sawControlA = true
        print("gesture=control_a action=rewind")
      case .pauseResume:
        sawControlS = true
        print("gesture=control_s action=pause_resume")
      case .fastForward:
        sawControlD = true
        print("gesture=control_d action=fast_forward")
      case .stop:
        sawControlB = true
        print("gesture=control_b action=stop")
      case .startFromBeginning:
        break
      }
      fflush(stdout)
    }

    guard monitor.start() else {
      let status = monitor.status
      print("shortcut_probe_failed=\(status.lastError ?? "listener_not_ready")")
      fflush(stdout)
      exit(EXIT_FAILURE)
    }

    let deadline = Date().addingTimeInterval(120)
    while Date() < deadline {
      if sawDoubleControl && sawControlOption && sawControlA && sawControlS && sawControlD && sawControlB {
        monitor.stop()
        print("shortcut_probe_passed=1")
        fflush(stdout)
        exit(EXIT_SUCCESS)
      }

      RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.1))
    }

    monitor.stop()
    print("shortcut_probe_timeout=1 saw_double_control=\(sawDoubleControl) saw_control_option=\(sawControlOption) saw_control_a=\(sawControlA) saw_control_s=\(sawControlS) saw_control_d=\(sawControlD) saw_control_b=\(sawControlB)")
    fflush(stdout)
    exit(EXIT_FAILURE)
  }

  private static func runLaunchAtLoginProbe() -> Never {
    LaunchAtLoginService.diagnosticLines().forEach { print($0) }
    if CommandLine.arguments.contains("--launch-at-login-register-probe") {
      do {
        try LaunchAtLoginService.setEnabled(true)
        print("register_result=ok")
      } catch {
        print("register_result=error")
        print("register_error=\(error.localizedDescription)")
      }
      LaunchAtLoginService.diagnosticLines().forEach { print("after_register_\($0)") }
    }
    if CommandLine.arguments.contains("--launch-at-login-unregister-probe") {
      do {
        try LaunchAtLoginService.setEnabled(false)
        print("unregister_result=ok")
      } catch {
        print("unregister_result=error")
        print("unregister_error=\(error.localizedDescription)")
      }
      LaunchAtLoginService.diagnosticLines().forEach { print("after_unregister_\($0)") }
    }
    fflush(stdout)
    exit(EXIT_SUCCESS)
  }

  private static func runClipboardProbe() -> Never {
    print("clipboard_probe_ready=1")
    fflush(stdout)

    do {
      let captured = try ClipboardTextCaptureService().capture()
      print("clipboard_probe_passed=1 source=\(captured.source.rawValue) length=\(captured.text.count)")
      fflush(stdout)
      exit(EXIT_SUCCESS)
    } catch {
      print("clipboard_probe_failed=1 error=\"\(error.localizedDescription)\"")
      fflush(stdout)
      exit(EXIT_FAILURE)
    }
  }

  private static func claudeSummaryProbeText(from arguments: [String]) -> String? {
    guard let flagIndex = arguments.firstIndex(of: "--claude-summary-probe") else {
      return nil
    }
    let textIndex = arguments.index(after: flagIndex)
    if textIndex < arguments.endIndex {
      let text = arguments[textIndex].trimmingCharacters(in: .whitespacesAndNewlines)
      if !text.isEmpty {
        return text
      }
    }
    return "AI Reader should summarize this probe text with Claude and return a compact result."
  }

  private static func runClaudeSummaryProbe(sourceText: String) -> Never {
    Task { @MainActor in
      do {
        try await runClaudeSummaryProbeAsync(sourceText: sourceText)
        exit(EXIT_SUCCESS)
      } catch {
        print("claude_summary_probe_failed=1 error=\"\(error.localizedDescription)\"")
        fflush(stdout)
        exit(EXIT_FAILURE)
      }
    }

    RunLoop.main.run()
    exit(EXIT_FAILURE)
  }

  @MainActor
  private static func runClaudeSummaryProbeAsync(sourceText: String) async throws {
    print("claude_summary_probe_ready=1")
    fflush(stdout)

    let anthropic = try ProviderConfiguration.requireAnthropicConfiguration()
    let prompt = SummaryPrompt.load(typeID: PreferenceKeys.currentSummaryPromptTypeID())
    let service = AnthropicSummaryService()
    let startedAt = DispatchTime.now().uptimeNanoseconds
    var firstTextAt: UInt64?
    var responseStartedAt: UInt64?
    var summary = ""

    let stream = service.streamSummary(
      AnthropicSummaryInput(configuration: anthropic, prompt: prompt, sourceText: sourceText)
    )

    for try await event in stream {
      let now = DispatchTime.now().uptimeNanoseconds
      switch event {
      case .responseStarted:
        responseStartedAt = now
        print("claude_headers_ms=\(formatMS(now - startedAt))")
      case .textDelta(let delta):
        if firstTextAt == nil {
          firstTextAt = now
          print("claude_first_text_ms=\(formatMS(now - startedAt))")
        }
        summary += delta
      case .messageStop:
        break
      }
      fflush(stdout)
    }

    let finishedAt = DispatchTime.now().uptimeNanoseconds

    print("claude_summary_probe_passed=1 length=\(summary.count)")
    if let responseStartedAt {
      print("claude_headers_to_done_ms=\(formatMS(finishedAt - responseStartedAt))")
    }
    if let firstTextAt {
      print("claude_first_text_to_done_ms=\(formatMS(finishedAt - firstTextAt))")
    }
    print("claude_done_ms=\(formatMS(finishedAt - startedAt))")
    print("summary_begin")
    print(summary)
    print("summary_end")

    let followUp = try await service.chat(
      AnthropicChatInput(
        configuration: anthropic,
        systemPrompt: """
          You are AI Reader's follow-up chat for a generated summary. Answer concisely using the summary and chat history. If the summary does not contain enough information, say that directly.
          """,
        messages: [
          AnthropicChatMessage(
            role: .user,
            content: "Use this Claude-generated summary as the source context for the follow-up chat:\n\n\(summary)"
          ),
          AnthropicChatMessage(role: .assistant, content: summary),
          AnthropicChatMessage(role: .user, content: "What should happen when a new source summary is generated?"),
        ]
      )
    )
    print("claude_chat_probe_passed=1 length=\(followUp.count)")
    print("follow_up_begin")
    print(followUp)
    print("follow_up_end")
    fflush(stdout)
  }

  private static func chainedSummaryTTSProbeText(from arguments: [String]) -> String? {
    guard let flagIndex = arguments.firstIndex(of: "--chained-summary-tts-probe") else {
      return nil
    }
    let textIndex = arguments.index(after: flagIndex)
    if textIndex < arguments.endIndex {
      let text = arguments[textIndex].trimmingCharacters(in: .whitespacesAndNewlines)
      if !text.isEmpty {
        return text
      }
    }
    return "AI Reader should stream Claude summary text into Cartesia continuations so audio can begin before the full summary has completed."
  }

  private static func runChainedSummaryTTSProbe(sourceText: String) -> Never {
    Task { @MainActor in
      do {
        try await runChainedSummaryTTSProbeAsync(sourceText: sourceText)
        exit(EXIT_SUCCESS)
      } catch {
        print("chained_summary_tts_probe_failed=1 error=\"\(error.localizedDescription)\"")
        fflush(stdout)
        exit(EXIT_FAILURE)
      }
    }

    RunLoop.main.run()
    exit(EXIT_FAILURE)
  }

  @MainActor
  private static func runChainedSummaryTTSProbeAsync(sourceText: String) async throws {
    print("chained_summary_tts_probe_ready=1")
    fflush(stdout)

    let anthropic = try ProviderConfiguration.requireAnthropicConfiguration()
    let cartesia = try ProviderConfiguration.requireReadConfiguration()
    let prompt = SummaryPrompt.load(typeID: PreferenceKeys.currentSummaryPromptTypeID())
    let anthropicService = AnthropicSummaryService()
    let cartesiaService = CartesiaWebSocketSpeechService()
    let playback = AudioPlaybackService()
    let bridge = TextSegmentStreamBridge()
    let sampleRate = 44_100
    let startedAt = DispatchTime.now().uptimeNanoseconds
    var chunker = StreamingSpeechChunker()
    var summary = ""

    try playback.prepareForStreaming(sampleRate: sampleRate)

    let speechTask = Task { @MainActor in
      var chunkCount = 0
      var byteCount = 0
      let input = CartesiaStreamingSpeechInput(
        configuration: cartesia,
        text: "",
        volume: PreferenceKeys.defaults.double(forKey: PreferenceKeys.volumeMultiplier) > 0
          ? PreferenceKeys.defaults.double(forKey: PreferenceKeys.volumeMultiplier)
          : 1,
        sampleRate: sampleRate
      )

      for try await event in cartesiaService.events(for: input, textSegments: bridge.stream) {
        let now = DispatchTime.now().uptimeNanoseconds
        switch event {
        case .connected(let reused):
          print("cartesia_connected_ms=\(formatMS(now - startedAt)) reused=\(reused)")
        case .requestSent:
          print("cartesia_first_continuation_sent_ms=\(formatMS(now - startedAt))")
        case .audioChunk(let chunk):
          chunkCount += 1
          byteCount += chunk.data.count
          if chunkCount == 1 {
            print("cartesia_first_chunk_ms=\(formatMS(now - startedAt))")
          }
          _ = try playback.enqueuePCMFloat32(chunk.data, sampleRate: sampleRate)
          if chunkCount == 1 {
            print("chained_first_audio_scheduled_ms=\(formatMS(DispatchTime.now().uptimeNanoseconds - startedAt))")
          }
        case .done:
          break
        }
        fflush(stdout)
      }

      let duration = playback.finishStreaming()
      print("cartesia_continuation_probe_passed=1 chunks=\(chunkCount) bytes=\(byteCount) audio_duration_s=\(String(format: "%.2f", duration))")
      fflush(stdout)
    }

    let stream = anthropicService.streamSummary(
      AnthropicSummaryInput(configuration: anthropic, prompt: prompt, sourceText: sourceText)
    )

    for try await event in stream {
      let now = DispatchTime.now().uptimeNanoseconds
      switch event {
      case .responseStarted:
        print("claude_headers_ms=\(formatMS(now - startedAt))")
      case .textDelta(let delta):
        if summary.isEmpty {
          print("claude_first_text_ms=\(formatMS(now - startedAt))")
        }
        summary += delta
        for segment in chunker.append(delta) {
          bridge.yield(segment)
        }
      case .messageStop:
        break
      }
      fflush(stdout)
    }

    for segment in chunker.finish() {
      bridge.yield(segment)
    }
    bridge.finish()
    try await speechTask.value

    print("chained_summary_tts_probe_passed=1 summary_length=\(summary.count) total_ms=\(formatMS(DispatchTime.now().uptimeNanoseconds - startedAt))")
    fflush(stdout)
  }

  private static func runPlaybackSeekProbe() -> Never {
    Task { @MainActor in
      do {
        try await runPlaybackSeekProbeAsync()
        exit(EXIT_SUCCESS)
      } catch {
        print("playback_seek_probe_failed=1 error=\"\(error.localizedDescription)\"")
        fflush(stdout)
        exit(EXIT_FAILURE)
      }
    }

    RunLoop.main.run()
    exit(EXIT_FAILURE)
  }

  @MainActor
  private static func runPlaybackSeekProbeAsync() async throws {
    print("playback_seek_probe_ready=1")
    fflush(stdout)

    let playback = AudioPlaybackService()
    let sampleRate = 44_100
    let syntheticDuration: TimeInterval = 30
    let pcm = makeSilentPCMFloat32(duration: syntheticDuration, sampleRate: sampleRate)

    try playback.prepareForStreaming(sampleRate: sampleRate)
    _ = try playback.enqueuePCMFloat32(pcm, sampleRate: sampleRate)
    let duration = playback.finishStreaming()
    try await Task.sleep(for: .milliseconds(300))

    let initial = playback.playbackSnapshot
    _ = playback.skip(by: 10)
    try await Task.sleep(for: .milliseconds(150))
    let afterFastForward = playback.playbackSnapshot

    _ = playback.skip(by: -10)
    try await Task.sleep(for: .milliseconds(150))
    let afterRewind = playback.playbackSnapshot

    _ = playback.startFromBeginning()
    try await Task.sleep(for: .milliseconds(150))
    let afterStart = playback.playbackSnapshot
    playback.stop()

    let fastForwardOK = afterFastForward.playbackTime >= initial.playbackTime + 8.5
    let rewindOK = afterRewind.playbackTime <= afterFastForward.playbackTime - 8.5
    let startOK = afterStart.playbackTime <= 0.75
    let durationOK = abs(duration - syntheticDuration) < 0.25

    print("synthetic_audio_duration_s=\(formatSeconds(duration))")
    print("initial_time_s=\(formatSeconds(initial.playbackTime))")
    print("after_fast_forward_time_s=\(formatSeconds(afterFastForward.playbackTime)) ok=\(fastForwardOK)")
    print("after_rewind_time_s=\(formatSeconds(afterRewind.playbackTime)) ok=\(rewindOK)")
    print("after_start_from_beginning_time_s=\(formatSeconds(afterStart.playbackTime)) ok=\(startOK)")
    print("duration_ok=\(durationOK)")

    guard fastForwardOK && rewindOK && startOK && durationOK else {
      print("playback_seek_probe_passed=0")
      fflush(stdout)
      exit(EXIT_FAILURE)
    }

    print("playback_seek_probe_passed=1")
    fflush(stdout)
  }

  private static func makeSilentPCMFloat32(duration: TimeInterval, sampleRate: Int) -> Data {
    let frameCount = max(Int((duration * Double(sampleRate)).rounded()), 0)
    return Data(count: frameCount * MemoryLayout<Float>.size)
  }

  private static func runTTSProbe() -> Never {
    Task { @MainActor in
      do {
        try await runTTSProbeAsync()
        exit(EXIT_SUCCESS)
      } catch {
        let message = await cartesiaProbeErrorMessage(error)
          .replacingOccurrences(of: "\"", with: "'")
        print("tts_probe_failed=1 error=\"\(message)\"")
        fflush(stdout)
        exit(EXIT_FAILURE)
      }
    }

    RunLoop.main.run()
    exit(EXIT_FAILURE)
  }

  @MainActor
  private static func runTTSProbeAsync() async throws {
    print("tts_probe_ready=1")
    fflush(stdout)

    var cartesia = try ProviderConfiguration.requireReadConfiguration()
    let environment = ProcessInfo.processInfo.environment
    if let modelOverride = environment["AI_READER_TTS_PROBE_MODEL"], !modelOverride.isEmpty {
      cartesia.modelID = modelOverride
    }
    let sampleRate = environment["AI_READER_TTS_PROBE_SAMPLE_RATE"].flatMap(Int.init) ?? 44_100
    let service = CartesiaWebSocketSpeechService()
    let playback = AudioPlaybackService()

    let warmStart = DispatchTime.now().uptimeNanoseconds
    try playback.warmUpStreaming(sampleRate: sampleRate)
    try await service.warmUp(configuration: cartesia)
    let warmEnd = DispatchTime.now().uptimeNanoseconds
    if let postWarmDelayMS = environment["AI_READER_TTS_PROBE_POST_WARM_DELAY_MS"].flatMap(Int.init),
      postWarmDelayMS > 0
    {
      print("post_warm_delay_ms=\(postWarmDelayMS)")
      fflush(stdout)
      try await Task.sleep(for: .milliseconds(postWarmDelayMS))
    }

    let captureStart = DispatchTime.now().uptimeNanoseconds
    let captured = try ClipboardTextCaptureService().capture()
    let captureEnd = DispatchTime.now().uptimeNanoseconds
    try playback.prepareForStreaming(sampleRate: sampleRate)
    let preparedEnd = DispatchTime.now().uptimeNanoseconds
    let bridge = TextSegmentStreamBridge()
    var chunker = StreamingSpeechChunker()
    var segmentCount = 0
    for segment in chunker.append(captured.text) {
      segmentCount += 1
      bridge.yield(segment)
    }
    for segment in chunker.finish() {
      segmentCount += 1
      bridge.yield(segment)
    }
    bridge.finish()

    let input = CartesiaStreamingSpeechInput(
      configuration: cartesia,
      text: "",
      volume: PreferenceKeys.defaults.double(forKey: PreferenceKeys.volumeMultiplier) > 0
        ? PreferenceKeys.defaults.double(forKey: PreferenceKeys.volumeMultiplier)
        : 1,
      sampleRate: sampleRate,
      maxBufferDelayMS: 0
    )

    print("clipboard_length=\(captured.text.count) source=\(captured.source.rawValue)")
    print("cartesia_model=\(cartesia.modelID) sample_rate=\(sampleRate) max_buffer_delay_ms=0")
    print("tts_mode=cartesia_continuations segment_count=\(segmentCount)")
    print("warmup_ms=\(formatMS(warmEnd - warmStart))")
    print("capture_ms=\(formatMS(captureEnd - captureStart)) local_audio_prepare_ms=\(formatMS(preparedEnd - captureStart))")
    fflush(stdout)

    var requestSentAt: UInt64?
    var firstChunkAt: UInt64?
    var firstScheduledAt: UInt64?
    var firstStepTimeMS: Int?
    var chunkCount = 0
    var byteCount = 0

    for try await event in service.events(for: input, textSegments: bridge.stream) {
      let now = DispatchTime.now().uptimeNanoseconds
      switch event {
      case .connected(let reused):
        print("websocket_connected_ms=\(formatMS(now - captureStart)) reused=\(reused)")
      case .requestSent:
        requestSentAt = now
        print("request_sent_ms=\(formatMS(now - captureStart))")
      case .audioChunk(let chunk):
        chunkCount += 1
        byteCount += chunk.data.count
        if firstChunkAt == nil {
          firstChunkAt = now
          firstStepTimeMS = chunk.stepTimeMS
          print("first_chunk_ms=\(formatMS(now - captureStart)) cartesia_step_time_ms=\(chunk.stepTimeMS.map(String.init) ?? "unknown")")
        }
        _ = try playback.enqueuePCMFloat32(chunk.data, sampleRate: sampleRate)
        if firstScheduledAt == nil {
          let scheduledAt = DispatchTime.now().uptimeNanoseconds
          firstScheduledAt = scheduledAt
          let firstAudioMS = milliseconds(scheduledAt - captureStart)
          print("first_audio_scheduled_ms=\(format(firstAudioMS)) target_50ms=\(firstAudioMS <= 50 ? "hit" : "miss")")
        }
      case .done:
        break
      }
      fflush(stdout)
    }

    let doneAt = DispatchTime.now().uptimeNanoseconds
    let duration = playback.finishStreaming()
    print("tts_probe_passed=1")
    print("chunks=\(chunkCount) bytes=\(byteCount) audio_duration_s=\(String(format: "%.2f", duration)) total_stream_ms=\(formatMS(doneAt - captureStart))")
    if let requestSentAt, let firstChunkAt {
      print("network_first_chunk_after_send_ms=\(formatMS(firstChunkAt - requestSentAt))")
    }
    if let firstStepTimeMS {
      print("cartesia_first_step_time_ms=\(firstStepTimeMS)")
    }
    fflush(stdout)
  }

  private static func milliseconds(_ nanoseconds: UInt64) -> Double {
    Double(nanoseconds) / 1_000_000
  }

  private static func formatMS(_ nanoseconds: UInt64) -> String {
    format(milliseconds(nanoseconds))
  }

  private static func format(_ value: Double) -> String {
    if value >= 100 {
      return "\(Int(value.rounded()))"
    }
    return String(format: "%.1f", value)
  }

  private static func formatSeconds(_ value: TimeInterval) -> String {
    String(format: "%.2f", value)
  }

  @MainActor
  private static func cartesiaProbeErrorMessage(_ error: Error) async -> String {
    guard isBadServerResponse(error),
      let cartesia = try? ProviderConfiguration.requireReadConfiguration()
    else {
      return error.localizedDescription
    }

    do {
      _ = try await CartesiaSpeechService().synthesize(
        CartesiaSpeechInput(
          configuration: cartesia,
          text: "AI Reader Cartesia diagnostics.",
          volume: 0.5
        )
      )
      return "Cartesia WebSocket handshake failed, but the HTTPS Cartesia diagnostic succeeded."
    } catch {
      return providerHTTPErrorMessage(error)
        ?? "Cartesia WebSocket handshake failed. Cartesia HTTPS diagnostic also failed: \(error.localizedDescription)"
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

    let object = try? JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any]
    let title = object?["title"] as? String ?? "\(provider) HTTP \(statusCode)"
    let message = object?["message"] as? String ?? body
    let code = (object?["error_code"] as? String).map { " (\($0), HTTP \(statusCode))" }
      ?? " (HTTP \(statusCode))"
    return "\(title): \(message)\(code)"
  }
}
