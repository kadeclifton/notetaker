import Foundation

/// The whisper.cpp models Murmur offers, from fastest to most accurate.
public struct WhisperModelOption: Sendable, Hashable, Identifiable {
    public var id: String
    public var title: String
    public var detail: String
    public var megabytes: Int

    public var fileName: String { "ggml-\(id).bin" }
    /// What goes in `transcription.whisperCpp.model` (relative to the settings folder).
    public var configPath: String { "models/\(fileName)" }
    public var url: URL { URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/\(fileName)")! }

    public static let base = WhisperModelOption(
        id: "base.en", title: "Fastest", detail: "base.en · good for short, clear dictation · any Mac", megabytes: 142)
    public static let small = WhisperModelOption(
        id: "small.en", title: "Balanced (recommended)", detail: "small.en · accurate and quick on any Apple Silicon Mac", megabytes: 466)
    public static let turbo = WhisperModelOption(
        id: "large-v3-turbo-q5_0", title: "Most accurate",
        detail: "large-v3-turbo · best with names and jargon, any language · slower on a MacBook Air", megabytes: 547)

    public static let catalog = [base, small, turbo]

    /// Which catalog entry a configured model path points at, if any.
    public static func matching(path: String) -> WhisperModelOption? {
        let file = (path as NSString).lastPathComponent
        return catalog.first { $0.fileName == file }
    }

    public func localURL(in directory: URL = AppPaths.directory) -> URL {
        directory.appendingPathComponent("models").appendingPathComponent(fileName)
    }
}

/// Small, comment-preserving edits to the settings file, for choices made in the menu.
public enum ConfigFileEdit {
    /// Points `transcription.whisperCpp.model` at `path`. The settings file's other model setting
    /// (cleanup's LLM) never ends in ".bin", so matching on that is enough. Nil if there is no
    /// Whisper model line to change.
    public static func settingWhisperModel(_ path: String, in text: String) -> String? {
        let pattern = #"("model"\s*:\s*")[^"]*\.bin(")"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range, in: text),
              let open = Range(match.range(at: 1), in: text),
              let close = Range(match.range(at: 2), in: text) else { return nil }
        return text.replacingCharacters(in: range, with: String(text[open]) + path + String(text[close]))
    }

    /// Same, for a file on disk. Returns false when the line is missing (settings file trimmed by hand).
    public static func setWhisperModel(_ path: String, in file: URL) throws -> Bool {
        let text = try String(contentsOf: file, encoding: .utf8)
        guard let updated = settingWhisperModel(path, in: text) else { return false }
        _ = try Config.parse(updated) // never write a file Murmur cannot read back
        try Data(updated.utf8).write(to: file, options: .atomic)
        return true
    }
}

extension ConfigFileEdit {
    /// Sets `"section": { "key": value }` in the settings text, keeping comments and layout.
    /// Adds the key, or the whole section, if it is missing. `json` is the value as JSON, e.g.
    /// `"\"clean\""` or `true`. The section must be flat (no nested objects). Nil if the result
    /// would not parse or `verify` rejects it.
    public static func setting(_ section: String, _ key: String, json: String, in text: String,
                               verify: (Config) -> Bool) -> String? {
        let whole = NSRange(text.startIndex..., in: text)
        var candidates: [String] = []
        let value = #"("(?:[^"\\]|\\.)*"|true|false|-?[0-9][0-9.]*)"#
        if let regex = try? NSRegularExpression(pattern: #"("\#(section)"\s*:\s*\{[^{}]*?"\#(key)"\s*:\s*)"# + value),
           let match = regex.firstMatch(in: text, range: whole),
           let old = Range(match.range(at: 2), in: text) {
            candidates.append(text.replacingCharacters(in: old, with: json))
        } else if let regex = try? NSRegularExpression(pattern: #""\#(section)"\s*:\s*\{"#),
                  let match = regex.firstMatch(in: text, range: whole),
                  let open = Range(match.range, in: text) {
            candidates.append(text.replacingCharacters(in: open, with: String(text[open]) + " \"\(key)\": \(json),"))
        } else if let close = text.lastIndex(of: "}") {
            // No such section (a settings file from an older Murmur): add one at the end.
            let addition = "\"\(section)\": { \"\(key)\": \(json) }\n"
            candidates.append(text.replacingCharacters(in: close..<close, with: ",\n  " + addition))
            candidates.append(text.replacingCharacters(in: close..<close, with: "  " + addition))
        }
        return candidates.first { candidate in
            (try? Config.parse(candidate)).map(verify) ?? false
        }
    }

    /// Same, on disk. False if it could not be applied.
    public static func set(_ section: String, _ key: String, json: String, in file: URL,
                           verify: (Config) -> Bool) throws -> Bool {
        let text = try String(contentsOf: file, encoding: .utf8)
        guard let updated = setting(section, key, json: json, in: text, verify: verify) else { return false }
        try Data(updated.utf8).write(to: file, options: .atomic)
        return true
    }

    /// A JSON string literal.
    public static func quoted(_ string: String) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: [string])) ?? Data("[\"\"]".utf8)
        return String(String(decoding: data, as: UTF8.self).dropFirst().dropLast())
    }
}
