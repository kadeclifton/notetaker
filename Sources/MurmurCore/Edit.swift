import Foundation

/// The prompt for editing selected text by voice: the selection and what you said to do with it.
public enum EditPrompt {
    public static let system = """
    You edit text for the user. You get a piece of text they selected and an instruction they \
    spoke. Apply the instruction to the text and reply with the edited text only: no quotes, no \
    preamble, no explanation, no notes about what changed. Keep the text's language, formatting \
    and line breaks unless the instruction asks otherwise. If the instruction is a question about \
    the text rather than a change, still reply with text that can replace the selection.
    """

    public static func user(text: String, instruction: String) -> String {
        "<instruction>\n\(instruction)\n</instruction>\n<text>\n\(text)\n</text>"
    }

    /// The reply without reasoning, wrappers, code fences or surrounding quotes.
    public static func clean(_ reply: String, original: String) -> String {
        var text = ComposePrompt.visible(reply)
        for (open, close) in [("<text>", "</text>"), ("```", "```")] {
            if text.hasPrefix(open), text.hasSuffix(close), text.count >= open.count + close.count {
                text = String(text.dropFirst(open.count).dropLast(close.count))
                if open == "```", let newline = text.firstIndex(of: "\n"), !text[..<newline].contains(" ") {
                    text = String(text[text.index(after: newline)...])  // a language tag after ```
                }
                text = text.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        let quotes: [(Character, Character)] = [("\"", "\""), ("\u{201C}", "\u{201D}")]
        if let (open, close) = quotes.first(where: { text.first == $0.0 && text.last == $0.1 }), text.count > 1,
           !(original.first == open && original.last == close) {
            text = String(text.dropFirst().dropLast())
        }
        return text
    }
}

public enum EditError: Error, CustomStringConvertible, Equatable {
    case noSelection
    case noModel
    case empty

    public var description: String {
        switch self {
        case .noSelection: return "Select some text first, then hold the hotkey with ⇧ and say how to change it."
        case .noModel: return "Editing needs a language model: start Ollama (ollama pull qwen3:8b) or add an API key."
        case .empty: return "The model returned nothing; the selection is unchanged."
        }
    }
}

/// Applies a spoken instruction to selected text with the Compose model.
public struct Editor: Sendable {
    public var chat: ChatModel
    public var timeout: TimeInterval

    public init(chat: ChatModel, timeout: TimeInterval = 120) {
        self.chat = chat
        self.timeout = timeout
    }

    public func edit(_ text: String, instruction: String) async throws -> String {
        let maxTokens = max(512, text.count / 2 + 512)
        let reply = try await chat.complete(system: EditPrompt.system, user: EditPrompt.user(text: text, instruction: instruction),
                                            maxTokens: maxTokens, timeout: timeout)
        let edited = EditPrompt.clean(reply, original: text)
        if edited.isEmpty { throw EditError.empty }
        return edited
    }
}

/// Decides when to offer to stop meeting notes: the call's app has not been using the microphone
/// for a while, or (when macOS cannot say which app uses it) nobody has spoken for several minutes.
public struct CallEndDetector: Sendable {
    public var quietApps: TimeInterval
    public var silence: TimeInterval
    private var appsQuietSince: Date?
    private var offered = false
    /// Another app used the mic during this meeting, so it is a call (not a meeting in the room,
    /// where Murmur is the only one listening).
    private var sawCall = false

    public init(quietApps: TimeInterval = 30, silence: TimeInterval = 300) {
        self.quietApps = quietApps
        self.silence = silence
    }

    /// - Parameters:
    ///   - othersUsingMic: another app is recording from a microphone; nil when macOS can't tell.
    ///   - sinceSpeech: seconds since anyone was heard in the meeting.
    /// - Returns: true once, when it is time to offer.
    public mutating func update(othersUsingMic: Bool?, sinceSpeech: TimeInterval, now: Date = Date()) -> Bool {
        if othersUsingMic == true {
            // The call is going (again): offer afresh next time it goes quiet.
            sawCall = true
            appsQuietSince = nil
            offered = false
        }
        guard !offered else { return false }
        var ended = sinceSpeech >= silence
        if othersUsingMic == false, sawCall {
            let since = appsQuietSince ?? now
            appsQuietSince = since
            ended = ended || now.timeIntervalSince(since) >= quietApps
        }
        if ended { offered = true }
        return ended
    }
}

/// Words dictated per day, kept on this Mac only, for the Settings stats.
public struct UsageStats: Codable, Equatable, Sendable {
    public struct Day: Codable, Equatable, Sendable {
        public var words = 0
        public var dictations = 0
        /// Seconds of talking that produced them.
        public var spoken: Double = 0
    }

    /// "2026-09-24" → that day's totals. Only the last `keepDays` are kept.
    public private(set) var days: [String: Day] = [:]
    public static let keepDays = 90
    /// Typing speed the time saved is measured against, words per minute.
    public static let typingWPM = 40.0

    public init() {}

    public mutating func record(words: Int, spoken: TimeInterval, on date: Date = Date(), calendar: Calendar = .current) {
        guard words > 0 else { return }
        let key = Self.key(date, calendar)
        var day = days[key] ?? Day()
        day.words += words
        day.dictations += 1
        day.spoken += spoken
        days[key] = day
        let cutoff = Self.key(calendar.date(byAdding: .day, value: -Self.keepDays, to: date) ?? date, calendar)
        days = days.filter { $0.key > cutoff }
    }

    public struct Summary: Equatable, Sendable {
        public var words = 0
        public var dictations = 0
        public var spoken: Double = 0
        /// Minutes it would have taken to type, minus the minutes spent talking.
        public var minutesSaved: Double { max(0, Double(words) / UsageStats.typingWPM - spoken / 60) }
    }

    /// The last `days` days, today included.
    public func summary(lastDays count: Int, now: Date = Date(), calendar: Calendar = .current) -> Summary {
        var total = Summary()
        for offset in 0..<count {
            guard let date = calendar.date(byAdding: .day, value: -offset, to: now), let day = days[Self.key(date, calendar)] else { continue }
            total.words += day.words
            total.dictations += day.dictations
            total.spoken += day.spoken
        }
        return total
    }

    static func key(_ date: Date, _ calendar: Calendar) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    public static func wordCount(_ text: String) -> Int {
        text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count
    }
}
