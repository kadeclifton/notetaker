#if os(macOS)
import AVFoundation
import CoreMedia
import Foundation
import Speech
import MurmurCore

enum AppleSpeechError: Error, CustomStringConvertible {
    case unsupportedLanguage(String)

    var description: String {
        switch self {
        case let .unsupportedLanguage(code):
            return "Apple's speech recognition does not support \"\(code)\" on this Mac. Pick another language, or Whisper, in Settings → Speech."
        }
    }
}

// SpeechAnalyzer is in the macOS 26 SDK, which comes with Xcode 26 (Swift 6.2). Older toolchains
// build Murmur without Apple's engine; Settings then only offers Whisper.
#if compiler(>=6.2)
/// Transcribes with the speech recognition built into macOS 26 (SpeechAnalyzer). It runs on this
/// Mac with a model macOS manages, so Murmur downloads nothing and keeps no server running.
/// Vocabulary is Whisper's; corrections apply to both.
@available(macOS 26, *)
struct AppleSpeechTranscriber: Transcriber {
    /// The language setting: "en", "de", or "auto" for this Mac's language.
    let language: String

    var name: String { "Apple speech (on this Mac)" }

    func transcribe(wav: Data, language: String?, prompt: String?) async throws -> String {
        try await transcribeSegments(wav: wav, language: language, prompt: prompt)
            .map(\.text).joined(separator: " ")
    }

    func transcribeSegments(wav: Data, language: String?, prompt: String?) async throws -> [TimedText] {
        let transcriber = try await Self.transcriber(for: language ?? self.language)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("murmur-speech-\(UUID().uuidString).wav")
        try wav.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let file = try AVAudioFile(forReading: url)
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let collector = Task { () throws -> [TimedText] in
            var segments: [TimedText] = []
            for try await result in transcriber.results {
                let text = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }
                segments.append(TimedText(start: result.range.start.seconds, end: result.range.end.seconds, text: text))
            }
            return segments
        }
        do {
            if let end = try await analyzer.analyzeSequence(from: file) {
                try await analyzer.finalizeAndFinish(through: end)
            } else {
                try await analyzer.cancelAndFinishNow()
            }
        } catch {
            collector.cancel()
            throw error
        }
        return try await collector.value
    }

    /// Downloads the language's model if macOS does not have it yet, so the first dictation does not
    /// wait for it. Settings calls this when Apple's engine or a new language is picked.
    static func prepare(language: String) async throws {
        _ = try await transcriber(for: language)
    }

    private static func transcriber(for setting: String) async throws -> SpeechTranscriber {
        let code = setting.trimmingCharacters(in: .whitespaces).lowercased()
        let wanted = code.isEmpty || code == "auto" ? Locale.current : Locale(identifier: code)
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: wanted) else {
            throw AppleSpeechError.unsupportedLanguage(code.isEmpty || code == "auto" ? wanted.identifier : code)
        }
        let transcriber = SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [], attributeOptions: [])
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await request.downloadAndInstall()
        }
        return transcriber
    }
}
#endif

enum AppleSpeech {
    /// Lets MurmurCore build the transcriber for transcription.engine "apple" on macOS 26 and later.
    static func register() {
        #if compiler(>=6.2)
        if #available(macOS 26, *) {
            SystemSpeech.makeTranscriber = { language in AppleSpeechTranscriber(language: language) }
        }
        #endif
    }

    /// See `AppleSpeechTranscriber.prepare`. Does nothing before macOS 26.
    static func prepare(language: String) async throws {
        #if compiler(>=6.2)
        if #available(macOS 26, *) { try await AppleSpeechTranscriber.prepare(language: language) }
        #endif
    }
}
#endif
