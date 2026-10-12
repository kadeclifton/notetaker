import Foundation

/// "Always write X as Y": a phrase the speech engine keeps getting wrong, and what to write
/// instead. Vocabulary only hints at a spelling; a correction is applied to every transcript.
public struct Correction: Codable, Equatable, Sendable, Hashable {
    /// What the engine writes, e.g. "cloud code". Matched as whole words, ignoring case.
    public var heard: String
    /// What it should be, e.g. "Claude Code".
    public var write: String

    public init(heard: String, write: String) {
        self.heard = heard
        self.write = write
    }
}

public enum Corrections {
    /// Applies every correction to `text`, longest phrase first so "cloud code" wins over "cloud".
    public static func apply(_ corrections: [Correction], to text: String) -> String {
        var result = text
        let usable = corrections
            .map { Correction(heard: $0.heard.trimmingCharacters(in: .whitespacesAndNewlines), write: $0.write) }
            .filter { !$0.heard.isEmpty && $0.heard != $0.write }
            .sorted { $0.heard.count > $1.heard.count }
        for correction in usable {
            // Whole words only: "cloud" must not touch "cloudy". Spaces inside the phrase match any
            // run of spaces, and the phrase may end before punctuation.
            let words = correction.heard.split(whereSeparator: \.isWhitespace).map { NSRegularExpression.escapedPattern(for: String($0)) }
            let pattern = #"(?<![\p{L}\p{N}])"# + words.joined(separator: #"\s+"#) + #"(?![\p{L}\p{N}])"#
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
            let range = NSRange(result.startIndex..., in: result)
            result = regex.stringByReplacingMatches(in: result, range: range,
                                                    withTemplate: NSRegularExpression.escapedTemplate(for: correction.write))
        }
        return result
    }
}

extension ConfigFileEdit {
    /// Replaces `transcription.corrections`, keeping the rest of the file as written.
    public static func settingCorrections(_ corrections: [Correction], in text: String) -> String? {
        let list = json(corrections)
        let verify: (Config) -> Bool = { $0.transcription.corrections == corrections }
        let whole = NSRange(text.startIndex..., in: text)
        if let regex = try? NSRegularExpression(pattern: #""corrections"\s*:\s*\[[^\]]*\]"#),
           let match = regex.firstMatch(in: text, range: whole),
           let range = Range(match.range, in: text) {
            let updated = text.replacingCharacters(in: range, with: "\"corrections\": " + list)
            return (try? Config.parse(updated)).map(verify) == true ? updated : nil
        }
        return setting("transcription", "corrections", json: list, in: text, verify: verify)
    }

    public static func setCorrections(_ corrections: [Correction], in file: URL) throws -> Bool {
        let text = try String(contentsOf: file, encoding: .utf8)
        guard let updated = settingCorrections(corrections, in: text) else { return false }
        try Data(updated.utf8).write(to: file, options: .atomic)
        return true
    }
}

/// Languages offered in Settings → Speech. Whisper and Apple's engine both take these codes.
public struct SpeechLanguage: Sendable, Equatable, Identifiable {
    public var code: String
    public var name: String
    public var id: String { code }

    public static let choices: [SpeechLanguage] = [
        .init(code: "en", name: "English"),
        .init(code: "auto", name: "Detect automatically"),
        .init(code: "es", name: "Spanish"),
        .init(code: "fr", name: "French"),
        .init(code: "de", name: "German"),
        .init(code: "it", name: "Italian"),
        .init(code: "pt", name: "Portuguese"),
        .init(code: "nl", name: "Dutch"),
        .init(code: "sv", name: "Swedish"),
        .init(code: "pl", name: "Polish"),
        .init(code: "ru", name: "Russian"),
        .init(code: "uk", name: "Ukrainian"),
        .init(code: "tr", name: "Turkish"),
        .init(code: "ar", name: "Arabic"),
        .init(code: "hi", name: "Hindi"),
        .init(code: "zh", name: "Chinese"),
        .init(code: "ja", name: "Japanese"),
        .init(code: "ko", name: "Korean"),
    ]

    /// Whether a setting other than English needs a model that understands more than English.
    public static func needsMultilingualModel(_ code: String) -> Bool {
        let code = code.trimmingCharacters(in: .whitespaces).lowercased()
        return !(code.isEmpty || code == "en" || code.hasPrefix("en-") || code.hasPrefix("en_"))
    }
}

extension WhisperModelOption {
    /// The ".en" models (Fastest, Balanced) only understand English.
    public var isEnglishOnly: Bool { id.hasSuffix(".en") }
}

/// Speech recognition built into macOS 26 (Apple's SpeechAnalyzer). It needs Apple's Speech
/// framework, so the Mac app provides it; elsewhere it is unavailable.
public enum SystemSpeech {
    /// Set by the Mac app at launch on macOS 26 and later. Takes the language setting ("en", "auto").
    nonisolated(unsafe) public static var makeTranscriber: (@Sendable (String) -> Transcriber)?

    public static var isAvailable: Bool { makeTranscriber != nil }
}
