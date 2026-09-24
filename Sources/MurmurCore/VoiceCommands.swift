import Foundation

/// A phrase that, said on its own, inserts saved text instead: "my address" → the full address.
public struct Snippet: Codable, Equatable, Sendable, Identifiable {
    /// What you say.
    public var say: String
    /// What gets inserted. Can span lines.
    public var insert: String

    public var id: String { say }

    public init(say: String, insert: String) {
        self.say = say
        self.insert = insert
    }
}

/// Words spoken to Murmur rather than dictated: snippets and "scratch that".
public enum VoiceCommands {
    /// Lowercase words only, so "My address." and "my address" match.
    public static func normalize(_ text: String) -> String {
        let words = text.lowercased().unicodeScalars.map { CharacterSet.alphanumerics.contains($0) || $0 == "'" ? Character($0) : " " }
        return String(words).split(separator: " ").joined(separator: " ")
    }

    /// The snippet's text when the whole utterance is its trigger phrase.
    public static func snippet(for transcript: String, in snippets: [Snippet]) -> String? {
        let said = normalize(transcript)
        guard !said.isEmpty else { return nil }
        return snippets.first { !normalize($0.say).isEmpty && normalize($0.say) == said }?.insert
    }

    /// Why a snippet cannot be saved as written, or nil when it is fine.
    public static func problem(with snippet: Snippet) -> String? {
        let said = normalize(snippet.say)
        if said.isEmpty { return "Type the phrase to say." }
        if snippet.insert.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "Type the text to insert." }
        if undoPhrases.contains(said) || said == "new line" || said == "new paragraph" {
            return "\u{201C}\(snippet.say)\u{201D} is already a Murmur command; pick another phrase."
        }
        return nil
    }

    static let undoPhrases: Set<String> = ["scratch that", "undo that", "delete that", "scratch that please", "undo"]

    /// The whole utterance is "scratch that" (or "undo that"): take back the last dictation.
    public static func isUndo(_ transcript: String) -> Bool {
        undoPhrases.contains(normalize(transcript))
    }

    /// "new line" and "new paragraph" said while dictating become line breaks. Whisper writes them
    /// as words with its own punctuation around them ("…today. New paragraph. Next…"), which goes.
    public static func applyFormatting(_ text: String) -> String {
        guard text.range(of: "new (line|paragraph)", options: [.regularExpression, .caseInsensitive]) != nil else { return text }
        var result = text
        for (phrase, breaks) in [("paragraph", "\n\n"), ("line", "\n")] {
            let pattern = "[ ,;:]*\\b[Nn]ew \(phrase)\\b[.,;:!]?[ ]*"
            result = result.replacingOccurrences(of: pattern, with: breaks, options: [.regularExpression, .caseInsensitive])
        }
        // Capitalize what follows each break, and never start or end with one.
        var out = ""
        var capitalizeNext = false
        for ch in result {
            if ch == "\n" {
                capitalizeNext = true
                out.append(ch)
            } else if capitalizeNext, ch.isLetter {
                out += ch.uppercased()
                capitalizeNext = false
            } else {
                if !ch.isWhitespace { capitalizeNext = false }
                out.append(ch)
            }
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The utterance ends in "scratch that": you changed your mind mid-sentence, so nothing is inserted.
    public static func isScratched(_ transcript: String) -> Bool {
        let said = normalize(transcript)
        return said == "scratch that" || said.hasSuffix(" scratch that")
    }
}

extension ConfigFileEdit {
    /// Replaces the top-level `snippets` list, keeping comments and layout.
    public static func setSnippets(_ snippets: [Snippet], in file: URL) throws -> Bool {
        try setTopLevel("snippets", json: json(snippets), in: file) { $0.snippets == snippets }
    }

    /// Sets the hotkey, e.g. "rightOption" or "ctrl+option+space".
    public static func setHotkey(_ hotkey: String, in file: URL) throws -> Bool {
        try setTopLevel("hotkey", json: quoted(hotkey), in: file) { $0.hotkey == hotkey }
    }
}

extension HotkeySpec {
    /// The settings value for a key pressed in the hotkey picker: "rightOption" for a modifier on
    /// its own, "ctrl+option+space" for a shortcut. Nil for keys Murmur cannot use (Esc, unknown).
    public static func configName(keyCode: Int64, modifiers: ShortcutModifiers, modifierOnly: Bool) -> String? {
        if modifierOnly {
            return ModifierKey.allCases.first { $0.keyCode == keyCode }?.rawValue
        }
        guard keyCode != 53, let key = keyNames[keyCode] else { return nil }
        var parts: [String] = []
        if modifiers.contains(.control) { parts.append("ctrl") }
        if modifiers.contains(.option) { parts.append("option") }
        if modifiers.contains(.shift) { parts.append("shift") }
        if modifiers.contains(.command) { parts.append("cmd") }
        // A letter or digit alone would stop that key typing anywhere.
        if parts.isEmpty && key.count == 1 { return nil }
        return (parts + [key]).joined(separator: "+")
    }

    /// One name per key code, skipping the second names some keys have.
    static let keyNames: [Int64: String] = {
        let aliases: Set<String> = ["enter", "backspace", "esc"]
        var names: [Int64: String] = [:]
        for (name, code) in keyCodes where !aliases.contains(name) { names[code] = name }
        return names
    }()
}
