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

    static let undoPhrases: Set<String> = ["scratch that", "undo that", "delete that", "scratch that please", "undo"]

    /// The whole utterance is "scratch that" (or "undo that"): take back the last dictation.
    public static func isUndo(_ transcript: String) -> Bool {
        undoPhrases.contains(normalize(transcript))
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
