import AVFoundation
import Foundation

@MainActor
final class AudioPlaybackService {
  struct PlaybackSnapshot: Equatable {
    var playbackTime: TimeInterval
    var bufferedDuration: TimeInterval
    var isPlaying: Bool
    var isStreaming: Bool
  }

  enum SeekResult: Equatable {
    case unavailable
    case moved(PlaybackSnapshot)
  }

  enum PlaybackToggleResult: Equatable {
    case unavailable
    case paused
    case resumed
  }

  private var currentPlayer: AVAudioPlayer?
  private var lastAudioData: Data?
  private var engine: AVAudioEngine?
  private var playerNode: AVAudioPlayerNode?
  private var streamFormat: AVAudioFormat?
  private var streamSampleRate = 44_100
  private var streamFrameCount: AVAudioFramePosition = 0
  private var streamPlaybackStartFrame: AVAudioFramePosition = 0
  private var currentPCMData: Data?
  private var lastPCMData: Data?
  private var lastPCMSampleRate = 44_100
  private var hasStreamingPlaybackSession = false
  private var streamPlaybackPaused = false

  var hasReplayableAudio: Bool {
    lastAudioData != nil || lastPCMData != nil
  }

  var hasControllablePlayback: Bool {
    currentPlayer != nil || hasStreamingPlaybackSession
  }

  var playbackSnapshot: PlaybackSnapshot {
    if let currentPlayer {
      return PlaybackSnapshot(
        playbackTime: currentPlayer.currentTime,
        bufferedDuration: currentPlayer.duration,
        isPlaying: currentPlayer.isPlaying,
        isStreaming: false
      )
    }

    let bufferedDuration = currentStreamingBufferedDuration
    let playbackTime = min(
      max(TimeInterval(currentStreamingPlaybackFrame) / Double(streamSampleRate), 0),
      bufferedDuration
    )
    return PlaybackSnapshot(
      playbackTime: playbackTime,
      bufferedDuration: bufferedDuration,
      isPlaying: playerNode?.isPlaying ?? false,
      isStreaming: hasStreamingPlaybackSession
    )
  }

  @discardableResult
  func play(_ data: Data) throws -> TimeInterval {
    stop()

    let player = try AVAudioPlayer(data: data)
    player.prepareToPlay()
    guard player.play() else {
      throw AudioPlaybackError.playbackFailed
    }

    currentPlayer = player
    lastAudioData = data
    lastPCMData = nil
    return player.duration
  }

  func warmUpStreaming(sampleRate: Int = 44_100) throws {
    try ensureStreamingEngine(sampleRate: sampleRate)
  }

  func prepareForStreaming(sampleRate: Int = 44_100) throws {
    stop()
    try ensureStreamingEngine(sampleRate: sampleRate)
    streamFrameCount = 0
    streamPlaybackStartFrame = 0
    currentPCMData = Data()
    hasStreamingPlaybackSession = true
    streamPlaybackPaused = false
    playerNode?.play()
  }

  @discardableResult
  func enqueuePCMFloat32(_ data: Data, sampleRate: Int = 44_100) throws -> TimeInterval {
    try ensureStreamingEngine(sampleRate: sampleRate)

    let alignedByteCount = data.count - (data.count % MemoryLayout<Float>.size)
    guard alignedByteCount > 0,
      let streamFormat,
      let playerNode,
      let buffer = AVAudioPCMBuffer(
        pcmFormat: streamFormat,
        frameCapacity: AVAudioFrameCount(alignedByteCount / MemoryLayout<Float>.size)
      ),
      let channel = buffer.floatChannelData?[0]
    else {
      return currentStreamDuration
    }

    buffer.frameLength = buffer.frameCapacity
    data.withUnsafeBytes { sourceBytes in
      let source = UnsafeRawBufferPointer(rebasing: sourceBytes.prefix(alignedByteCount))
      let destination = UnsafeMutableRawBufferPointer(start: channel, count: alignedByteCount)
      destination.copyMemory(from: source)
    }

    playerNode.scheduleBuffer(buffer, completionHandler: nil)
    if !streamPlaybackPaused && !playerNode.isPlaying {
      playerNode.play()
    }

    currentPCMData?.append(data.prefix(alignedByteCount))
    streamFrameCount += AVAudioFramePosition(buffer.frameLength)
    return currentStreamDuration
  }

  @discardableResult
  func finishStreaming() -> TimeInterval {
    let hasCurrentAudio = currentPCMData?.isEmpty == false
    if let currentPCMData, hasCurrentAudio {
      lastPCMData = currentPCMData
      lastPCMSampleRate = streamSampleRate
      lastAudioData = nil
    }
    currentPCMData = nil
    if !hasCurrentAudio {
      hasStreamingPlaybackSession = false
      streamPlaybackPaused = false
    }
    return currentStreamDuration
  }

  @discardableResult
  func replay() throws -> TimeInterval {
    if let lastPCMData {
      try prepareForStreaming(sampleRate: lastPCMSampleRate)
      let duration = try enqueuePCMFloat32(lastPCMData, sampleRate: lastPCMSampleRate)
      finishStreaming()
      return duration
    }

    guard let lastAudioData else {
      throw AudioPlaybackError.noReplayAudio
    }
    return try play(lastAudioData)
  }

  func pauseOrResume() -> PlaybackToggleResult {
    if let currentPlayer {
      if currentPlayer.isPlaying {
        currentPlayer.pause()
        return .paused
      }

      guard currentPlayer.play() else {
        return .unavailable
      }
      return .resumed
    }

    guard let playerNode, hasStreamingPlaybackSession else {
      return .unavailable
    }

    if playerNode.isPlaying {
      streamPlaybackPaused = true
      playerNode.pause()
      return .paused
    }

    streamPlaybackPaused = false
    playerNode.play()
    return .resumed
  }

  func stop() {
    currentPlayer?.stop()
    currentPlayer = nil
    playerNode?.stop()
    streamFrameCount = 0
    streamPlaybackStartFrame = 0
    currentPCMData = nil
    hasStreamingPlaybackSession = false
    streamPlaybackPaused = false
  }

  @discardableResult
  func skip(by seconds: TimeInterval) -> SeekResult {
    if let currentPlayer {
      let targetTime = min(max(currentPlayer.currentTime + seconds, 0), currentPlayer.duration)
      currentPlayer.currentTime = targetTime
      return .moved(playbackSnapshot)
    }

    return seekStreamingPlayback(by: seconds)
  }

  @discardableResult
  func startFromBeginning() -> SeekResult {
    if let currentPlayer {
      currentPlayer.currentTime = 0
      if !currentPlayer.isPlaying {
        guard currentPlayer.play() else {
          return .unavailable
        }
      }
      return .moved(playbackSnapshot)
    }

    return seekStreamingPlayback(toFrame: 0, shouldPlay: true)
  }

  private var currentStreamDuration: TimeInterval {
    TimeInterval(streamFrameCount) / Double(streamSampleRate)
  }

  private var currentStreamingBufferedDuration: TimeInterval {
    let dataFrameCount = (currentPCMData ?? lastPCMData).map { $0.count / MemoryLayout<Float>.size } ?? 0
    let totalFrames = max(Int(streamFrameCount), dataFrameCount)
    return TimeInterval(totalFrames) / Double(streamSampleRate)
  }

  private func seekStreamingPlayback(by seconds: TimeInterval) -> SeekResult {
    guard hasStreamingPlaybackSession,
      let playerNode,
      let sourceData = currentPCMData ?? lastPCMData
    else {
      return .unavailable
    }

    let bytesPerFrame = MemoryLayout<Float>.size
    let totalFrames = AVAudioFramePosition(sourceData.count / bytesPerFrame)
    guard totalFrames > 0 else {
      return .unavailable
    }

    let deltaFrames = AVAudioFramePosition((seconds * Double(streamSampleRate)).rounded())
    let currentFrame = min(max(currentStreamingPlaybackFrame, 0), totalFrames)
    let targetFrame = clampedStreamingSeekFrame(currentFrame + deltaFrames, totalFrames: totalFrames)
    let wasPlaying = playerNode.isPlaying

    return seekStreamingPlayback(toFrame: targetFrame, shouldPlay: wasPlaying)
  }

  private func seekStreamingPlayback(
    toFrame requestedFrame: AVAudioFramePosition,
    shouldPlay: Bool
  ) -> SeekResult {
    guard hasStreamingPlaybackSession,
      let playerNode,
      let sourceData = currentPCMData ?? lastPCMData
    else {
      return .unavailable
    }

    let bytesPerFrame = MemoryLayout<Float>.size
    let totalFrames = AVAudioFramePosition(sourceData.count / bytesPerFrame)
    guard totalFrames > 0 else {
      return .unavailable
    }

    let targetFrame = clampedStreamingSeekFrame(requestedFrame, totalFrames: totalFrames)

    playerNode.stop()
    streamPlaybackStartFrame = targetFrame

    guard let buffer = makeStreamingBuffer(from: sourceData, startingAt: targetFrame) else {
      return .unavailable
    }

    playerNode.scheduleBuffer(buffer, completionHandler: nil)
    if shouldPlay {
      streamPlaybackPaused = false
      playerNode.play()
    } else {
      streamPlaybackPaused = true
    }
    return .moved(playbackSnapshot)
  }

  private var currentStreamingPlaybackFrame: AVAudioFramePosition {
    guard let playerNode,
      let nodeTime = playerNode.lastRenderTime,
      let playerTime = playerNode.playerTime(forNodeTime: nodeTime)
    else {
      return streamPlaybackStartFrame
    }

    return streamPlaybackStartFrame + AVAudioFramePosition(playerTime.sampleTime)
  }

  private func clampedStreamingSeekFrame(
    _ requestedFrame: AVAudioFramePosition,
    totalFrames: AVAudioFramePosition
  ) -> AVAudioFramePosition {
    guard totalFrames > 0 else {
      return 0
    }
    if requestedFrame >= totalFrames {
      let tailFrames = min(totalFrames, AVAudioFramePosition(Double(streamSampleRate) * 0.25))
      return max(totalFrames - tailFrames, 0)
    }
    return min(max(requestedFrame, 0), totalFrames - 1)
  }

  private func makeStreamingBuffer(from data: Data, startingAt frame: AVAudioFramePosition) -> AVAudioPCMBuffer? {
    let bytesPerFrame = MemoryLayout<Float>.size
    let startByte = Int(frame) * bytesPerFrame
    guard startByte < data.count,
      let streamFormat
    else {
      return nil
    }

    let byteCount = data.count - startByte
    let alignedByteCount = byteCount - (byteCount % bytesPerFrame)
    guard alignedByteCount > 0,
      let buffer = AVAudioPCMBuffer(
        pcmFormat: streamFormat,
        frameCapacity: AVAudioFrameCount(alignedByteCount / bytesPerFrame)
      ),
      let channel = buffer.floatChannelData?[0]
    else {
      return nil
    }

    buffer.frameLength = buffer.frameCapacity
    data.withUnsafeBytes { sourceBytes in
      guard let baseAddress = sourceBytes.baseAddress else {
        return
      }
      let source = UnsafeRawBufferPointer(start: baseAddress.advanced(by: startByte), count: alignedByteCount)
      let destination = UnsafeMutableRawBufferPointer(start: channel, count: alignedByteCount)
      destination.copyMemory(from: source)
    }

    return buffer
  }

  private func ensureStreamingEngine(sampleRate: Int) throws {
    if engine == nil || streamFormat == nil || streamSampleRate != sampleRate {
      let nextEngine = AVAudioEngine()
      let nextPlayerNode = AVAudioPlayerNode()
      guard let nextFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: Double(sampleRate),
        channels: 1,
        interleaved: false
      ) else {
        throw AudioPlaybackError.invalidStreamingFormat
      }

      nextEngine.attach(nextPlayerNode)
      nextEngine.connect(nextPlayerNode, to: nextEngine.mainMixerNode, format: nextFormat)

      engine = nextEngine
      playerNode = nextPlayerNode
      streamFormat = nextFormat
      streamSampleRate = sampleRate
    }

    guard let engine else {
      throw AudioPlaybackError.invalidStreamingFormat
    }

    if !engine.isRunning {
      engine.prepare()
      try engine.start()
    }
  }
}

enum AudioPlaybackError: LocalizedError {
  case playbackFailed
  case noReplayAudio
  case invalidStreamingFormat

  var errorDescription: String? {
    switch self {
    case .playbackFailed:
      return "Could not play the generated audio."
    case .noReplayAudio:
      return "There is no generated audio to replay yet."
    case .invalidStreamingFormat:
      return "Could not prepare low-latency audio playback."
    }
  }
}
