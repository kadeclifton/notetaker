import Foundation

public enum RecordingMode: Equatable, Sendable {
    /// Recording while the hotkey is held.
    case hold
    /// Started by a double-tap; records until the next tap.
    case handsFree
}

public enum DictationInput: Equatable, Sendable {
    case hotkeyDown
    case hotkeyUp
    /// Some other key went down while a modifier-only hotkey was held.
    case otherKeyDown
    case escape
    /// Periodic clock tick while recording, for the double-tap window and time limit.
    case tick
}

public enum FinishReason: Equatable, Sendable {
    case released
    case tappedToStop
    case timeLimit
}

public enum DiscardReason: Equatable, Sendable {
    case escape
    /// A single short tap that was not followed by a second one.
    case singleTap
    /// The hotkey was part of a shortcut like fn+arrow.
    case chord
    case timeLimit
}

public enum DictationAction: Equatable, Sendable {
    case startRecording(RecordingMode)
    case modeChanged(RecordingMode)
    /// Stop the microphone and transcribe what was recorded.
    case finishRecording(FinishReason)
    /// Stop the microphone and throw the audio away.
    case discardRecording(DiscardReason)
    /// Esc with nothing recording: cancel any transcription still running.
    case cancelProcessing
}

/// Turns hotkey presses into recording decisions. Pure and clock-injected so it can be tested.
///
/// - Press and hold: records until release.
/// - Tap, then press again within the double-tap window: hands-free until the next press.
/// - A single tap on its own does nothing (its audio is dropped).
/// - Esc drops the recording, or cancels processing when nothing is recording.
/// - Every recording stops at `maxDuration`, including a hold whose key-up got lost.
public struct DictationStateMachine: Sendable {
    public struct Timing: Equatable, Sendable {
        public var tapMax: TimeInterval
        public var doubleTapWindow: TimeInterval
        public var chordGuard: TimeInterval
        public var maxDuration: TimeInterval
        public var transcribeOnTimeLimit: Bool

        public init(tapMax: TimeInterval = 0.25, doubleTapWindow: TimeInterval = 0.35,
                    chordGuard: TimeInterval = 0.4, maxDuration: TimeInterval = 300,
                    transcribeOnTimeLimit: Bool = true) {
            self.tapMax = tapMax
            self.doubleTapWindow = doubleTapWindow
            self.chordGuard = chordGuard
            self.maxDuration = maxDuration
            self.transcribeOnTimeLimit = transcribeOnTimeLimit
        }

        public init(_ config: Config) {
            self.init(
                tapMax: Double(config.timing.tapMaxMs) / 1000,
                doubleTapWindow: Double(config.timing.doubleTapWindowMs) / 1000,
                chordGuard: Double(config.timing.chordGuardMs) / 1000,
                maxDuration: max(10, config.handsFree.maxMinutes * 60),
                transcribeOnTimeLimit: config.handsFree.onTimeLimit.lowercased() != "discard"
            )
        }
    }

    public enum State: Equatable, Sendable {
        case idle
        /// Hotkey is down and the microphone is on.
        case holding(recordingSince: TimeInterval, pressedAt: TimeInterval)
        /// A short tap just ended; still recording while we wait to see if a second tap follows.
        case awaitingSecondTap(recordingSince: TimeInterval, releasedAt: TimeInterval)
        case handsFree(recordingSince: TimeInterval)
    }

    public private(set) var state: State = .idle
    public var timing: Timing

    public init(timing: Timing = Timing()) {
        self.timing = timing
    }

    public var isRecording: Bool { state != .idle }

    public var mode: RecordingMode? {
        switch state {
        case .idle: return nil
        case .holding, .awaitingSecondTap: return .hold
        case .handsFree: return .handsFree
        }
    }

    public func elapsed(at now: TimeInterval) -> TimeInterval {
        switch state {
        case .idle: return 0
        case let .holding(since, _), let .awaitingSecondTap(since, _), let .handsFree(since):
            return max(0, now - since)
        }
    }

    public func remaining(at now: TimeInterval) -> TimeInterval {
        max(0, timing.maxDuration - elapsed(at: now))
    }

    /// Back to idle without emitting anything, e.g. when the microphone failed to start.
    public mutating func reset() {
        state = .idle
    }

    public mutating func handle(_ input: DictationInput, at now: TimeInterval) -> [DictationAction] {
        switch (state, input) {
        case (.idle, .hotkeyDown):
            // Start the microphone right away so the first word is not clipped.
            state = .holding(recordingSince: now, pressedAt: now)
            return [.startRecording(.hold)]

        case (.idle, .escape):
            return [.cancelProcessing]

        case (.idle, _):
            return []

        case let (.holding(since, pressedAt), .hotkeyUp):
            if now - pressedAt < timing.tapMax {
                state = .awaitingSecondTap(recordingSince: since, releasedAt: now)
                return []
            }
            state = .idle
            return [.finishRecording(.released)]

        case let (.holding(_, pressedAt), .otherKeyDown):
            guard now - pressedAt < timing.chordGuard else { return [] }
            state = .idle
            return [.discardRecording(.chord)]

        case (.holding, .hotkeyDown):
            // Key repeat or a missed key-up; the key is still down either way.
            return timeLimitCheck(now)

        case let (.awaitingSecondTap(since, _), .hotkeyDown):
            state = .handsFree(recordingSince: since)
            return [.modeChanged(.handsFree)]

        case let (.awaitingSecondTap(_, releasedAt), .tick):
            if now - releasedAt >= timing.doubleTapWindow {
                state = .idle
                return [.discardRecording(.singleTap)]
            }
            return []

        case (.awaitingSecondTap, .otherKeyDown):
            state = .idle
            return [.discardRecording(.singleTap)]

        case (.awaitingSecondTap, .hotkeyUp):
            return []

        case (.handsFree, .hotkeyDown):
            state = .idle
            return [.finishRecording(.tappedToStop)]

        case (.handsFree, .hotkeyUp), (.handsFree, .otherKeyDown):
            // The release of the second tap, or typing while hands-free: keep going.
            return []

        case (_, .escape):
            state = .idle
            return [.discardRecording(.escape)]

        case (.holding, .tick), (.handsFree, .tick):
            return timeLimitCheck(now)
        }
    }

    private mutating func timeLimitCheck(_ now: TimeInterval) -> [DictationAction] {
        guard elapsed(at: now) >= timing.maxDuration else { return [] }
        state = .idle
        return timing.transcribeOnTimeLimit ? [.finishRecording(.timeLimit)] : [.discardRecording(.timeLimit)]
    }
}
