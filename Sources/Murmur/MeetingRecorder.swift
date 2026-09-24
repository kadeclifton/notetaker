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
    }

    let fileURL: URL
    let startedAt = Date()
    private let setup: Setup
    private let mic = AudioRecorder()
    private var system: SystemAudioCapture?
    private var micChunker: AudioChunker
    private var systemChunker: AudioChunker
    private var transcript = MeetingTranscript()
    private var pumpTimer: Timer?
    /// Pieces are transcribed one at a time, in order.
    private var queueTail: Task<Void, Never>?
    private var pendingPieces = 0
    private(set) var warnings: [String] = []
    /// What has been transcribed so far, for the live window.
    var liveTranscript: MeetingTranscript { transcript }
    /// Pieces recorded but not transcribed yet.
    var piecesPending: Int { pendingPieces }

    /// Called every couple of seconds with fresh state for the menu bar.
    var onChange: (() -> Void)?
    /// Called once when the time limit is reached; the owner should stop the meeting.
    var onTimeLimit: (() -> Void)?

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
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            mic.start { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
        if setup.config.captureSystemAudio {
            let capture = SystemAudioCapture()
            do {
                try await capture.start()
                capture.onStop = { [weak self] error in
                    Task { @MainActor [weak self] in
                        self?.warnings.append("Call audio stopped: \(error.localizedDescription)")
                        self?.system = nil
                    }
                }
                system = capture
            } catch {
                // Keep going with the mic alone rather than losing the meeting; say so in the notes.
                warnings.append("\(error)")
                Permissions.reopenIfQuit()
                Permissions.open(.screenRecording)
            }
        }
        try writeFile(summary: nil)
        pumpTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.pump() }
        }
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
        guard !Audio.isSilent(chunk.samples) else { return }
        let previous = queueTail
        let transcriber = setup.transcriber
        let language = setup.language
        let prompt = setup.prompt
        pendingPieces += 1
        queueTail = Task { [weak self] in
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
                self.transcript.add(segments, chunkStart: chunk.start, speaker: speaker)
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
        let rest = await withCheckedContinuation { (continuation: CheckedContinuation<[Float], Never>) in
            mic.stop { continuation.resume(returning: $0) }
        }
        for chunk in micChunker.append(rest) { enqueue(chunk, speaker: .me) }
        if let chunk = micChunker.flush() { enqueue(chunk, speaker: .me) }
        if let system {
            await system.stop()
            for chunk in systemChunker.append(system.takeRecorded()) { enqueue(chunk, speaker: .others) }
            if let chunk = systemChunker.flush() { enqueue(chunk, speaker: .others) }
            self.system = nil
        }

        if pendingPieces > 0 { progress("Transcribing the last \(pendingPieces == 1 ? "piece" : "\(pendingPieces) pieces")…") }
        await queueTail?.value

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
