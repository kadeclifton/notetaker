import Foundation

/// Transcribes a long dictation while it is still being recorded: every ~20 s of audio (cut at a
/// pause) goes to the transcriber in the background, so letting go of the key only leaves the last
/// piece to do. Short dictations never reach a cut and are transcribed in one go as before.
public actor IncrementalTranscription {
    private let transcriber: Transcriber
    private let language: String?
    private let prompt: String?
    private var chunker: AudioChunker
    private var pieces: [String] = []
    private var queue: Task<Void, Never>?
    private var failure: Error?
    private var cancelled = false
    /// Whether any piece was sent early; if not, `finish` leaves the whole clip to the caller.
    private var started = false

    public init(transcriber: Transcriber, language: String?, prompt: String?, chunkSeconds: TimeInterval = 20) {
        self.transcriber = transcriber
        self.language = language
        self.prompt = prompt
        chunker = AudioChunker(target: chunkSeconds)
    }

    public func append(_ samples: [Float]) {
        guard !cancelled, !samples.isEmpty else { return }
        for chunk in chunker.append(samples) {
            started = true
            enqueue(chunk.samples)
        }
    }

    /// The whole transcript: waits for the pieces in flight and transcribes the rest. Nil when the
    /// recording was too short to start early; transcribe it as one clip then.
    public func finish() async throws -> String? {
        guard started, !cancelled else { return nil }
        if let rest = chunker.flush() { enqueue(rest.samples) }
        let queue = self.queue
        // Esc while waiting stops the pieces still to come.
        await withTaskCancellationHandler {
            await queue?.value
        } onCancel: {
            Task { await self.cancel() }
        }
        try Task.checkCancellation()
        if let failure { throw failure }
        return TranscriptFilter.clean(pieces.joined(separator: " "))
    }

    public func cancel() {
        cancelled = true
        queue?.cancel()
    }

    /// One piece at a time, in order. The end of the text so far is passed as the prompt so the
    /// next piece continues the sentence in the same style.
    private func enqueue(_ samples: [Float]) {
        let previous = queue
        queue = Task {
            await previous?.value
            await self.transcribe(samples)
        }
    }

    private func transcribe(_ samples: [Float]) async {
        guard !cancelled, failure == nil, !Audio.isSilent(samples) else { return }
        let context = pieces.joined(separator: " ").split(separator: " ").suffix(30).joined(separator: " ")
        let prompt = [self.prompt, context.isEmpty ? nil : context].compactMap { $0 }.joined(separator: " ")
        do {
            let wav = Audio.wav(samples: Audio.boosted(Audio.trimmingSilence(samples)))
            let text = try await transcriber.transcribe(wav: wav, language: language, prompt: prompt.isEmpty ? nil : prompt)
            let clean = TranscriptFilter.clean(text)
            if !clean.isEmpty { pieces.append(clean) }
        } catch {
            if !cancelled { failure = error }
        }
    }
}
