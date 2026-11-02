#if os(macOS)
import AppKit
import MurmurCore

/// Records a meeting: your mic as "Me" and the call's audio as "Others". Audio is transcribed in
/// ~30 s pieces while the meeting runs, and the notes file is rewritten after every piece, so a
/// crash loses at most the last half minute. Stopping adds the summary.
@MainActor
final class MeetingRecorder {
    struct Setup {
        var config: MeetingConfig
        var transcriber: Transcriber
        var language: String?
        var prompt: String?
        var summarizer: ChatModel?
        /// "Always write X as Y", as for dictation.
        var corrections: [Correction] = []
    }

    let fileURL: URL
    let startedAt = Date()
    private var setup: Setup
    private let mic = AudioRecorder()
    private var system: CallAudioSource?
    private var micChunker: AudioChunker
    private var systemChunker: AudioChunker
    private var transcript = MeetingTranscript()
    private var pumpTimer: Timer?
    /// Each side's pieces are transcribed one at a time, in order. When the transcriber takes two
    /// clips at once (a hosted API, Apple's engine), your words and the call's have a queue each and
    /// are transcribed side by side; otherwise they share one (whisper.cpp does one clip at a time).
    private var queueTails: [Speaker: Task<Void, Never>] = [:]
    private var pendingPieces = 0
    private(set) var warnings: [String] = []
    /// The loudest moment heard from each side so far, to warn when one stayed silent throughout.
    private var loudest: [Speaker: Float] = [:]
    /// What has been transcribed so far, for the live window.
    var liveTranscript: MeetingTranscript { transcript }
    /// Pieces recorded but not transcribed yet.
    var piecesPending: Int { pendingPieces }
    /// When someone (you or the call) was last heard, for "the call seems to be over".
    private(set) lazy var lastSpeech = startedAt

    /// Called every couple of seconds with fresh state for the menu bar.
    var onChange: (() -> Void)?
    /// Called once when the time limit is reached; the owner should stop the meeting.
    var onTimeLimit: (() -> Void)?

    /// The model that writes the summary at the end. Murmur may find a local one only after the
    /// recording has started, so it can be set until then.
    var summarizer: ChatModel? {
        get { setup.summarizer }
        set {
            setup.summarizer = newValue
            // Its name is in the notes' details; never rewrite notes that are finished.
            if stoppedAt == nil { try? writeFile(summary: nil) }
        }
    }

    private var stoppedAt: Date?
    var elapsed: TimeInterval { (stoppedAt ?? Date()).timeIntervalSince(startedAt) }

    private init(setup: Setup, fileURL: URL) {
        self.setup = setup
        self.fileURL = fileURL
        micChunker = AudioChunker(target: setup.config.chunkSeconds)
        systemChunker = AudioChunker(target: setup.config.chunkSeconds)
    }

    static func start(_ setup: Setup) async throws -> MeetingRecorder {
        let folder = URL(fileURLWithPath: AppPaths.expandTilde(setup.config.folder), isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let recorder = MeetingRecorder(setup: setup, fileURL: MeetingNotes.availableURL(in: folder, for: Date()))
        try await recorder.begin()
        return recorder
    }

    private func begin() async throws {
        // A call app switching the mic to voice processing (FaceTime does) silently stops a
        // recording; for a whole meeting, the recorder notices and starts again.
        mic.keepsRunning = true
        // The mic and the call's audio start together: each takes a moment (the call's audio
        // more, the first time macOS sets up its tap) and neither needs the other.
        var callAudio: Task<Result<CallAudioSource, Error>, Never>?
        if setup.config.captureSystemAudio {
            callAudio = Task { () async -> Result<CallAudioSource, Error> in
                do { return .success(try await Self.startCallAudio()) } catch { return .failure(error) }
            }
        }
        let micStarted: Result<Void, Error> = await withCheckedContinuation { continuation in
            mic.start { error in
                if let error { continuation.resume(returning: .failure(error)) } else { continuation.resume(returning: .success(())) }
            }
        }
        let call = await callAudio?.value
        if case let .failure(error) = micStarted {
            // No meeting without the mic: do not leave the call's audio running.
            if case let .success(capture)? = call { await capture.stop() }
            throw error
        }
        switch call {
        case let .success(capture)?:
            capture.onStop = { [weak self] error in
                Task { @MainActor [weak self] in
                    self?.warnings.append("Call audio stopped: \(error.localizedDescription)")
                    self?.system = nil
                }
            }
            system = capture
        case let .failure(error)?:
            // Keep going with the mic alone rather than losing the meeting; say so in the notes.
            warnings.append("\(error)")
            Permissions.reopenIfQuit()
            Permissions.open(.screenRecording)
        case nil:
            break
        }
        try writeFile(summary: nil)
        pumpTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.pump() }
        }
    }

    /// A Core Audio tap where there is one (it also hears FaceTime and iPhone calls, which
    /// ScreenCaptureKit cannot), else ScreenCaptureKit.
    private static func startCallAudio() async throws -> CallAudioSource {
        if #available(macOS 14.2, *) {
            let tap = SystemAudioTap()
            do {
                try await tap.start()
                return tap
            } catch {
                // Fall through to ScreenCaptureKit, which may still work.
            }
        }
        let capture = SystemAudioCapture()
        try await capture.start()
        return capture
    }

    private func pump() {
        for chunk in micChunker.append(mic.takeRecorded()) { enqueue(chunk, speaker: .me) }
        if let system {
            for chunk in systemChunker.append(system.takeRecorded()) { enqueue(chunk, speaker: .others) }
        }
        if elapsed >= setup.config.maxHours * 3600 {
            onTimeLimit?()
            onTimeLimit = nil
        }
        onChange?()
    }

    private func enqueue(_ chunk: AudioChunk, speaker: Speaker) {
        let level = Audio.loudest(chunk.samples)
        loudest[speaker] = max(loudest[speaker] ?? 0, level)
        guard !Audio.isSilent(chunk.samples) else { return }
        if level >= MeetingNoise.quiet { lastSpeech = Date() }
        let transcriber = setup.transcriber
        let lane: Speaker = transcriber.takesConcurrentRequests ? speaker : .me
        let previous = queueTails[lane]
        let language = setup.language
        let prompt = setup.prompt
        pendingPieces += 1
        queueTails[lane] = Task { [weak self] in
            await previous?.value
            let result: Result<[TimedText], Error>
            do {
                let wav = Audio.wav(samples: chunk.samples)
                result = .success(try await transcriber.transcribeSegments(wav: wav, language: language, prompt: prompt))
            } catch {
                result = .failure(error)
            }
            guard let self else { return }
            self.pendingPieces -= 1
            switch result {
            case let .success(segments):
                let corrections = self.setup.corrections
                let heard = segments.filter { !MeetingNoise.isInvented($0.text, loudest: level) }
                    .map { TimedText(start: $0.start, end: $0.end, text: Corrections.apply(corrections, to: $0.text)) }
                self.transcript.add(heard, chunkStart: chunk.start, speaker: speaker)
            case let .failure(error):
                self.warnings.append("Could not transcribe \(speaker.rawValue) at \(MeetingTranscript.clock(chunk.start)): \(error)")
            }
            try? self.writeFile(summary: nil)
        }
    }

    /// Stops recording, transcribes what is left, and writes the summary. Returns the notes file.
    func stop(summarize: Bool, progress: @escaping @MainActor (String) -> Void) async -> URL {
        stoppedAt = Date()
        pumpTimer?.invalidate()
        pumpTimer = nil
        // Both sides stop together; neither waits for the other.
        var callStopped: Task<Void, Never>?
        if let system { callStopped = Task { await system.stop() } }
        let rest = await withCheckedContinuation { (continuation: CheckedContinuation<[Float], Never>) in
            mic.stop { continuation.resume(returning: $0) }
        }
        for chunk in micChunker.append(rest) { enqueue(chunk, speaker: .me) }
        if let chunk = micChunker.flush() { enqueue(chunk, speaker: .me) }
        if let system {
            await callStopped?.value
            for chunk in systemChunker.append(system.takeRecorded()) { enqueue(chunk, speaker: .others) }
            if let chunk = systemChunker.flush() { enqueue(chunk, speaker: .others) }
            self.system = nil
        }

        let minutes = elapsed / 60
        if let note = MeetingNoise.warning(for: .me, loudest: loudest[.me], device: mic.deviceName, minutes: minutes) {
            warnings.append(note)
        }
        if setup.config.captureSystemAudio, !warnings.contains(where: { $0.hasPrefix("Call audio") }),
           let note = MeetingNoise.warning(for: .others, loudest: loudest[.others], device: nil, minutes: minutes) {
            warnings.append(note)
        }

        if pendingPieces > 0 { progress("Transcribing the last \(pendingPieces == 1 ? "piece" : "\(pendingPieces) pieces")…") }
        for tail in queueTails.values { await tail.value }

        var summary: String?
        if summarize, setup.config.summarize, !transcript.isEmpty {
            if let chat = setup.summarizer {
                progress("Summarizing with \(chat.name)…")
                do {
                    summary = try await MeetingSummarizer(chat: chat, timeout: setup.config.summaryTimeoutSeconds)
                        .summarize(transcript)
                } catch {
                    summary = "_The summary failed: \(error). The full transcript is below._"
                }
            } else {
                summary = "_No summary: no language model was found. Start Ollama or LM Studio (or add an API key) "
                    + "before your next meeting._"
            }
        }
        try? writeFile(summary: summary, finished: true)
        return fileURL
    }

    private func writeFile(summary: String?, finished: Bool = false) throws {
        let date = DateFormatter.localizedString(from: startedAt, dateStyle: .medium, timeStyle: .short)
        var details = "**Started:** \(date) · **Length:** \(Self.length(elapsed))"
        if !finished { details += " (recording…)" }
        details += " · **Transcribed by:** \(setup.transcriber.name)"
        if let chat = setup.summarizer, setup.config.summarize { details += " · **Summary by:** \(chat.name)" }
        if system == nil && !setup.config.captureSystemAudio { details += "\n\n_Microphone only: call audio recording is off._" }
        for warning in warnings { details += "\n\n> ⚠️ \(warning)" }
        let text = MeetingNotes.markdown(title: "Meeting, \(date)", details: details, summary: summary, transcript: transcript)
        try Data(text.utf8).write(to: fileURL, options: .atomic)
    }

    static func length(_ seconds: TimeInterval) -> String {
        let minutes = Int((seconds / 60).rounded())
        return minutes < 60 ? "\(minutes) min" : "\(minutes / 60) h \(minutes % 60) min"
    }
}
#endif
