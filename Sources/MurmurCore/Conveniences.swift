import Foundation

/// The last few things Murmur inserted, for the menu's Recent list. Kept in memory only.
public struct RecentDictations: Sendable, Equatable {
    public struct Item: Sendable, Equatable, Identifiable {
        public var id = UUID()
        public var text: String
        public var mode: DictationMode
        public var date: Date

        /// One line for a menu: the start of the text, whitespace collapsed.
        public var preview: String {
            let flat = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            return flat.count > 60 ? String(flat.prefix(57)).trimmingCharacters(in: .whitespaces) + "…" : flat
        }
    }

    public private(set) var items: [Item] = []
    public let limit: Int

    public init(limit: Int = 10) {
        self.limit = limit
    }

    /// Newest first. Saying the same thing twice in a row keeps one entry.
    public mutating func add(_ text: String, mode: DictationMode, at date: Date = Date()) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        items.removeAll { $0.text == trimmed }
        items.insert(Item(text: trimmed, mode: mode, date: date), at: 0)
        if items.count > limit { items.removeLast(items.count - limit) }
    }

    public mutating func clear() { items.removeAll() }
}

/// Whether the focused UI element can take typed text, from its Accessibility role. Pasting with
/// nothing to receive it loses the words, so Murmur keeps them on the clipboard instead. Unknown
/// roles count as text: a missed paste is worse than a harmless one.
public enum TextTarget {
    public enum Verdict: Equatable {
        case text
        case notText
    }

    /// Roles that never take typing: the desktop, lists, buttons, images and the like.
    static let nonTextRoles: Set<String> = [
        "AXApplication", "AXWindow", "AXList", "AXOutline", "AXTable", "AXBrowser", "AXButton",
        "AXImage", "AXMenuBar", "AXMenu", "AXMenuItem", "AXDockItem", "AXCheckBox", "AXRadioButton",
        "AXPopUpButton", "AXSlider", "AXToolbar", "AXSplitGroup", "AXScrollBar",
    ]

    /// - Parameters:
    ///   - role: the focused element's AXRole, or nil when nothing has keyboard focus.
    ///   - editable: whether its value can be set or it has a text selection, if known.
    public static func verdict(role: String?, editable: Bool?) -> Verdict {
        if editable == true { return .text }
        guard let role else { return .notText }
        return nonTextRoles.contains(role) ? .notText : .text
    }
}

extension WhisperModelOption {
    /// The speech model to start with on a Mac with this much memory: an 8 GB MacBook Air feels
    /// snappier with the small model; anything bigger handles the balanced one easily.
    public static func recommended(memoryBytes: UInt64 = ProcessInfo.processInfo.physicalMemory) -> WhisperModelOption {
        Double(memoryBytes) / 1_073_741_824 < 12 ? .base : .small
    }
}

extension ConfigFileEdit {
    /// Replaces `transcription.vocabulary` with `words`, keeping the rest of the file as written.
    public static func settingVocabulary(_ words: [String], in text: String) -> String? {
        let list = "[" + words.map(quoted).joined(separator: ", ") + "]"
        let verify: (Config) -> Bool = { $0.transcription.vocabulary == words }
        let whole = NSRange(text.startIndex..., in: text)
        if let regex = try? NSRegularExpression(pattern: #""vocabulary"\s*:\s*\[[^\]]*\]"#),
           let match = regex.firstMatch(in: text, range: whole),
           let range = Range(match.range, in: text) {
            let updated = text.replacingCharacters(in: range, with: "\"vocabulary\": " + list)
            return (try? Config.parse(updated)).map(verify) == true ? updated : nil
        }
        // No vocabulary key yet: add one to the transcription section (or the section itself).
        return setting("transcription", "vocabulary", json: list, in: text, verify: verify)
    }

    public static func setVocabulary(_ words: [String], in file: URL) throws -> Bool {
        let text = try String(contentsOf: file, encoding: .utf8)
        guard let updated = settingVocabulary(words, in: text) else { return false }
        try Data(updated.utf8).write(to: file, options: .atomic)
        return true
    }
}
