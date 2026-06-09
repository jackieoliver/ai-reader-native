import CoreGraphics
import Foundation

public enum ModifierTapGesture: Equatable, Sendable {
  case doubleControl
  case controlOption
  case rewind
  case pauseResume
  case fastForward
  case startFromBeginning
  case stop
}

public struct ModifierTapHotkeyMonitorStatus: Equatable, Sendable {
  public var isRunning: Bool
  public var tapActive: Bool
  public var observedFlagsChangedCount: Int
  public var disabledCount: Int
  public var reenableAttemptCount: Int
  public var reenableSuccessCount: Int
  public var lastDisabledReason: String?
  public var lastError: String?

  public var ready: Bool {
    isRunning && tapActive && lastError == nil
  }
}

public final class ModifierTapHotkeyMonitor: @unchecked Sendable {
  public var onGesture: (@MainActor (ModifierTapGesture) -> Void)?
  public var playbackKeyGesturesEnabled: Bool {
    get { withStateLock { storedPlaybackKeyGesturesEnabled } }
    set { withStateLock { storedPlaybackKeyGesturesEnabled = newValue } }
  }
  public var doubleTapInterval: TimeInterval {
    get { withStateLock { storedDoubleTapInterval } }
    set { withStateLock { storedDoubleTapInterval = newValue } }
  }

  private var eventTap: CFMachPort?
  private var runLoopSource: CFRunLoopSource?
  private var runLoop: CFRunLoop?
  private var eventThread: Thread?
  private var shutdownSemaphore: DispatchSemaphore?
  private let stateLock = NSLock()
  private var shouldKeepRunning = false
  private var storedIsRunning = false
  private var tapActive = false
  private var observedFlagsChangedCount = 0
  private var disabledCount = 0
  private var reenableAttemptCount = 0
  private var reenableSuccessCount = 0
  private var lastDisabledReason: String?
  private var lastError: String?
  private var lastFlags: CGEventFlags = []
  private var lastControlTapAt: CFAbsoluteTime?
  private var storedPlaybackKeyGesturesEnabled = false
  private var storedDoubleTapInterval: TimeInterval

  public var isRunning: Bool {
    withStateLock { storedIsRunning }
  }

  public var status: ModifierTapHotkeyMonitorStatus {
    withStateLock {
      ModifierTapHotkeyMonitorStatus(
        isRunning: storedIsRunning,
        tapActive: tapActive,
        observedFlagsChangedCount: observedFlagsChangedCount,
        disabledCount: disabledCount,
        reenableAttemptCount: reenableAttemptCount,
        reenableSuccessCount: reenableSuccessCount,
        lastDisabledReason: lastDisabledReason,
        lastError: lastError
      )
    }
  }

  public init(doubleTapInterval: TimeInterval = 0.42) {
    self.storedDoubleTapInterval = doubleTapInterval
  }

  deinit {
    stop()
  }

  @discardableResult
  public func start() -> Bool {
    let startup = EventTapStartup()
    let shutdown = DispatchSemaphore(value: 0)
    let thread = Thread { [self] in
      runEventTap(startup: startup, shutdown: shutdown)
    }
    thread.name = "AIReaderModifierTapHotkeyMonitor"

    let shouldStart = withStateLock { () -> Bool in
      guard !storedIsRunning, eventThread == nil else {
        return false
      }
      shouldKeepRunning = true
      tapActive = false
      lastError = nil
      lastDisabledReason = nil
      eventThread = thread
      shutdownSemaphore = shutdown
      return true
    }

    guard shouldStart else {
      return status.ready
    }

    thread.start()

    guard startup.wait(timeout: 1.5) else {
      recordError("Timed out while starting the modifier shortcut listener.")
      stop()
      return false
    }

    guard startup.succeeded else {
      recordError(startup.errorMessage ?? "Could not start the modifier shortcut listener.")
      stop()
      return false
    }

    return status.ready
  }

  public func stop() {
    let stopTarget = withStateLock { () -> (CFRunLoop?, Thread?, DispatchSemaphore?) in
      shouldKeepRunning = false
      storedIsRunning = false
      tapActive = false
      return (runLoop, eventThread, shutdownSemaphore)
    }
    if let loop = stopTarget.0 {
      CFRunLoopStop(loop)
    }
    if let thread = stopTarget.1, thread !== Thread.current, let shutdown = stopTarget.2 {
      _ = shutdown.wait(timeout: .now() + 1.0)
    }
  }

  fileprivate func handle(type: CGEventType, event: CGEvent) -> Bool {
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
      markTapDisabled(reason: type == .tapDisabledByTimeout ? "timeout" : "user_input")
      reenableTap()
      return false
    }

    if type == .keyDown {
      return handleKeyDown(event)
    }

    guard type == .flagsChanged else {
      return false
    }

    let gesture = withStateLock { () -> ModifierTapGesture? in
      observedFlagsChangedCount += 1

      let flags = event.flags
      let optionDown = flags.contains(.maskAlternate)
      let controlDown = flags.contains(.maskControl)
      let controlWasDown = lastFlags.contains(.maskControl)
      let controlOptionDown = controlDown && optionDown
      let controlOptionWasDown = lastFlags.contains(.maskControl) && lastFlags.contains(.maskAlternate)
      let interval = storedDoubleTapInterval
      var detectedGesture: ModifierTapGesture?

      if controlOptionDown && !controlOptionWasDown && isOnly([.maskControl, .maskAlternate], activeIn: flags) {
        lastControlTapAt = nil
        detectedGesture = .controlOption
      } else if controlDown && !controlWasDown && isOnly(.maskControl, activeIn: flags) {
        detectedGesture = registerControlTap(now: CFAbsoluteTimeGetCurrent(), interval: interval)
      }

      lastFlags = flags
      return detectedGesture
    }

    if let gesture {
      emit(gesture)
    }
    return false
  }

  private func registerControlTap(now: CFAbsoluteTime, interval: TimeInterval) -> ModifierTapGesture? {
    guard let previous = lastControlTapAt,
      now - previous <= interval
    else {
      lastControlTapAt = now
      return nil
    }

    lastControlTapAt = nil
    return .doubleControl
  }

  private func emit(_ gesture: ModifierTapGesture) {
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      Task { @MainActor in
        self.onGesture?(gesture)
      }
    }
  }

  private func handleKeyDown(_ event: CGEvent) -> Bool {
    guard let gesture = Self.playbackKeyGesture(
      keyCode: event.getIntegerValueField(.keyboardEventKeycode),
      flags: event.flags
    ) else {
      return false
    }

    guard playbackKeyGesturesEnabled else {
      return false
    }

    guard event.getIntegerValueField(.keyboardEventAutorepeat) == 0 else {
      return true
    }

    emit(gesture)
    return true
  }

  static func playbackKeyGesture(keyCode: Int64, flags: CGEventFlags) -> ModifierTapGesture? {
    guard isOnly(.maskControl, activeIn: flags) else {
      return nil
    }

    switch keyCode {
    case 0:
      return .rewind
    case 1:
      return .pauseResume
    case 2:
      return .fastForward
    case 11:
      return .stop
    default:
      return nil
    }
  }

  private func isOnly(_ modifier: CGEventFlags, activeIn flags: CGEventFlags) -> Bool {
    Self.isOnly(modifier, activeIn: flags)
  }

  private static func isOnly(_ modifier: CGEventFlags, activeIn flags: CGEventFlags) -> Bool {
    let relevant: CGEventFlags = [.maskAlternate, .maskControl, .maskCommand, .maskShift]
    return flags.intersection(relevant) == modifier
  }

  private func runEventTap(startup: EventTapStartup, shutdown: DispatchSemaphore) {
    autoreleasepool {
      defer {
        shutdown.signal()
      }
      guard let currentRunLoop = CFRunLoopGetCurrent() else {
        let message = ModifierTapHotkeyMonitorError.runLoopSourceCreateFailed.localizedDescription
        recordError(message)
        startup.fail(message)
        return
      }
      withStateLock {
        runLoop = currentRunLoop
      }

      do {
        try installTap(on: currentRunLoop)
        startup.succeed()

        while shouldContinueRunning {
          _ = CFRunLoopRunInMode(.defaultMode, 0.5, true)
        }

        uninstallTap(on: currentRunLoop)
      } catch {
        recordError(error.localizedDescription)
        startup.fail(error.localizedDescription)
        uninstallTap(on: currentRunLoop)
      }
    }
  }

  private func installTap(on runLoop: CFRunLoop) throws {
    let mask = CGEventMask(1 << CGEventType.flagsChanged.rawValue)
      | CGEventMask(1 << CGEventType.keyDown.rawValue)
    guard let tap = CGEvent.tapCreate(
      tap: .cgSessionEventTap,
      place: .headInsertEventTap,
      options: .defaultTap,
      eventsOfInterest: mask,
      callback: modifierTapCallback,
      userInfo: Unmanaged.passUnretained(self).toOpaque()
    ) else {
      throw ModifierTapHotkeyMonitorError.tapCreateFailed
    }

    guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
      CFMachPortInvalidate(tap)
      throw ModifierTapHotkeyMonitorError.runLoopSourceCreateFailed
    }

    CFRunLoopAddSource(runLoop, source, .commonModes)
    CGEvent.tapEnable(tap: tap, enable: true)
    guard CGEvent.tapIsEnabled(tap: tap) else {
      CFRunLoopRemoveSource(runLoop, source, .commonModes)
      CFMachPortInvalidate(tap)
      throw ModifierTapHotkeyMonitorError.tapEnableFailed
    }

    withStateLock {
      eventTap = tap
      runLoopSource = source
      storedIsRunning = true
      tapActive = true
      lastError = nil
    }
  }

  private func uninstallTap(on runLoop: CFRunLoop) {
    let tapAndSource = withStateLock { () -> (CFMachPort?, CFRunLoopSource?) in
      let currentTap = eventTap
      let currentSource = runLoopSource
      eventTap = nil
      runLoopSource = nil
      self.runLoop = nil
      eventThread = nil
      shutdownSemaphore = nil
      storedIsRunning = false
      tapActive = false
      shouldKeepRunning = false
      lastFlags = []
      lastControlTapAt = nil
      return (currentTap, currentSource)
    }

    if let tap = tapAndSource.0 {
      CGEvent.tapEnable(tap: tap, enable: false)
      CFMachPortInvalidate(tap)
    }
    if let source = tapAndSource.1 {
      CFRunLoopRemoveSource(runLoop, source, .commonModes)
    }
  }

  private var shouldContinueRunning: Bool {
    withStateLock { shouldKeepRunning }
  }

  private func markTapDisabled(reason: String) {
    withStateLock {
      disabledCount += 1
      lastDisabledReason = reason
      tapActive = false
    }
  }

  private func reenableTap() {
    let tap = withStateLock { () -> CFMachPort? in
      reenableAttemptCount += 1
      return eventTap
    }
    guard let tap else {
      recordError("Modifier shortcut listener disappeared before it could be re-enabled.")
      return
    }

    CGEvent.tapEnable(tap: tap, enable: true)
    let enabled = CGEvent.tapIsEnabled(tap: tap)
    withStateLock {
      tapActive = enabled
      if enabled {
        reenableSuccessCount += 1
        lastError = nil
      } else {
        lastError = "Modifier shortcut listener could not be re-enabled."
      }
    }
  }

  private func recordError(_ message: String) {
    withStateLock {
      lastError = message
      tapActive = false
      storedIsRunning = false
    }
  }

  private func withStateLock<T>(_ body: () -> T) -> T {
    stateLock.lock()
    defer { stateLock.unlock() }
    return body()
  }
}

private enum ModifierTapHotkeyMonitorError: LocalizedError {
  case tapCreateFailed
  case runLoopSourceCreateFailed
  case tapEnableFailed

  var errorDescription: String? {
    switch self {
    case .tapCreateFailed:
      return "Could not create a keyboard CGEventTap. Shortcut monitoring may not be usable for this app identity."
    case .runLoopSourceCreateFailed:
      return "Could not create a run-loop source for the modifier shortcut listener."
    case .tapEnableFailed:
      return "The modifier shortcut listener was created but could not be enabled."
    }
  }
}

private final class EventTapStartup: @unchecked Sendable {
  private let semaphore = DispatchSemaphore(value: 0)
  private let lock = NSLock()
  private var completed = false
  private var storedSucceeded = false
  private var storedErrorMessage: String?

  var succeeded: Bool {
    lock.lock()
    defer { lock.unlock() }
    return storedSucceeded
  }

  var errorMessage: String? {
    lock.lock()
    defer { lock.unlock() }
    return storedErrorMessage
  }

  func succeed() {
    complete(succeeded: true, errorMessage: nil)
  }

  func fail(_ errorMessage: String) {
    complete(succeeded: false, errorMessage: errorMessage)
  }

  func wait(timeout: TimeInterval) -> Bool {
    semaphore.wait(timeout: .now() + timeout) == .success
  }

  private func complete(succeeded: Bool, errorMessage: String?) {
    lock.lock()
    guard !completed else {
      lock.unlock()
      return
    }
    completed = true
    storedSucceeded = succeeded
    storedErrorMessage = errorMessage
    lock.unlock()
    semaphore.signal()
  }
}

private let modifierTapCallback: CGEventTapCallBack = { _, type, event, userInfo in
  guard let userInfo else {
    return Unmanaged.passUnretained(event)
  }

  let monitor = Unmanaged<ModifierTapHotkeyMonitor>.fromOpaque(userInfo).takeUnretainedValue()
  if monitor.handle(type: type, event: event) {
    return nil
  }
  return Unmanaged.passUnretained(event)
}
