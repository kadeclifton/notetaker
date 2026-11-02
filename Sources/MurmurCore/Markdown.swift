import Foundation

/// One line-level piece of a Markdown document, for showing meeting notes and Compose writing with
/// real headings, bullets and check boxes. Bold, italics and links inside the text are left as
/// Markdown for the view to render.
public enum MarkdownBlock: Equatable, Sendable {
    case heading(level: Int, text: String)
    /// `indent` counts nesting levels: two spaces or a tab each.
    case bullet(text: String, indent: Int)
    /// "- [ ] Owner: task"
    case task(text: String, done: Bool, indent: Int)
    /// "1. text"; `marker` is "1." as written.
    case numbered(marker: String, text: String, indent: Int)
    case quote(String)
    case rule
    /// Consecutive lines of plain text, joined by line breaks.
    case paragraph(String)
    /// A meeting transcript line: "**[00:12] Me:** text".
    case turn(time: String, speaker: String, text: String)
}

public enum MarkdownBlocks {
    public static func parse(_ markdown: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        var paragraph: [String] = []
        var quote: [String] = []

        func flush() {
            if !paragraph.isEmpty { blocks.append(.paragraph(paragraph.joined(separator: "\n"))) }
            if !quote.isEmpty { blocks.append(.quote(quote.joined(separator: "\n"))) }
            paragraph = []
            quote = []
        }

        // isNewline also splits "\r\n", which Swift counts as one character.
        for rawLine in markdown.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            let line = String(rawLine)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                flush()
                continue
            }
            if let block = heading(trimmed) ?? rule(trimmed) ?? turn(trimmed) ?? listItem(line) {
                flush()
                blocks.append(block)
                continue
            }
            if trimmed.hasPrefix(">") {
                if !paragraph.isEmpty { flush() }
                quote.append(String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces))
                continue
            }
            if !quote.isEmpty { flush() }
            paragraph.append(trimmed)
        }
        flush()
        return blocks
    }

    static func heading(_ line: String) -> MarkdownBlock? {
        let hashes = line.prefix { $0 == "#" }.count
        guard (1...6).contains(hashes) else { return nil }
        let rest = line.dropFirst(hashes)
        guard rest.first == " " else { return nil }
        return .heading(level: hashes, text: rest.trimmingCharacters(in: .whitespaces))
    }

    static func rule(_ line: String) -> MarkdownBlock? {
        let compact = line.filter { $0 != " " }
        guard compact.count >= 3, let first = compact.first, "-*_".contains(first), compact.allSatisfy({ $0 == first }) else {
            return nil
        }
        return .rule
    }

    /// "**[00:12] Me:** text", as `MeetingTranscript.markdown()` writes it.
    static func turn(_ line: String) -> MarkdownBlock? {
        guard line.hasPrefix("**["), let close = line.range(of: "]") else { return nil }
        let time = String(line[line.index(line.startIndex, offsetBy: 3)..<close.lowerBound])
        guard !time.isEmpty, time.allSatisfy({ $0.isNumber || $0 == ":" }) else { return nil }
        let afterTime = line[close.upperBound...]
        guard let end = afterTime.range(of: ":**") else { return nil }
        let speaker = afterTime[..<end.lowerBound].trimmingCharacters(in: .whitespaces)
        guard !speaker.isEmpty, !speaker.contains("*") else { return nil }
        let text = afterTime[end.upperBound...].trimmingCharacters(in: .whitespaces)
        return .turn(time: time, speaker: speaker, text: text)
    }

    static func listItem(_ line: String) -> MarkdownBlock? {
        var indentWidth = 0
        for character in line {
            if character == " " { indentWidth += 1 } else if character == "\t" { indentWidth += 2 } else { break }
        }
        let indent = indentWidth / 2
        let body = line.trimmingCharacters(in: .whitespaces)
        if let marker = body.first, "-*+".contains(marker), body.dropFirst().first == " " {
            let text = body.dropFirst(2).trimmingCharacters(in: .whitespaces)
            for (box, done) in [("[ ]", false), ("[x]", true), ("[X]", true)] where text.hasPrefix(box) {
                let rest = text.dropFirst(box.count)
                guard rest.isEmpty || rest.first == " " else { continue }
                return .task(text: rest.trimmingCharacters(in: .whitespaces), done: done, indent: indent)
            }
            return .bullet(text: text, indent: indent)
        }
        let digits = body.prefix { $0.isNumber }
        if !digits.isEmpty, digits.count <= 3 {
            let after = body.dropFirst(digits.count)
            if let punctuation = after.first, ".)".contains(punctuation), after.dropFirst().first == " " {
                return .numbered(marker: String(digits) + String(punctuation),
                                 text: after.dropFirst(2).trimmingCharacters(in: .whitespaces), indent: indent)
            }
        }
        return nil
    }
}

/// "Today", "Yesterday", "Previous 7 Days"…: how Library lists group pieces and meetings by date.
public enum DayGroup: Hashable, Sendable, Comparable {
    case today
    case yesterday
    case previous7Days
    case previous30Days
    /// The first of the month, for anything older.
    case month(Date)

    public static func of(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> DayGroup {
        let day = calendar.startOfDay(for: date)
        let today = calendar.startOfDay(for: now)
        let days = calendar.dateComponents([.day], from: day, to: today).day ?? 0
        switch days {
        case ..<1: return .today
        case 1: return .yesterday
        case 2...7: return .previous7Days
        case 8...30: return .previous30Days
        default:
            let start = calendar.date(from: calendar.dateComponents([.year, .month], from: date)) ?? day
            return .month(start)
        }
    }

    public func title(calendar: Calendar = .current, now: Date = Date()) -> String {
        switch self {
        case .today: return "Today"
        case .yesterday: return "Yesterday"
        case .previous7Days: return "Previous 7 Days"
        case .previous30Days: return "Previous 30 Days"
        case let .month(start):
            let sameYear = calendar.component(.year, from: start) == calendar.component(.year, from: now)
            let formatter = DateFormatter()
            formatter.calendar = calendar
            formatter.timeZone = calendar.timeZone
            formatter.setLocalizedDateFormatFromTemplate(sameYear ? "MMMM" : "MMMM yyyy")
            return formatter.string(from: start)
        }
    }

    /// Newest first.
    public static func < (lhs: DayGroup, rhs: DayGroup) -> Bool {
        switch (lhs, rhs) {
        case let (.month(a), .month(b)): return a > b
        case (.month, _): return false
        case (_, .month): return true
        default: return lhs.rank < rhs.rank
        }
    }

    private var rank: Int {
        switch self {
        case .today: return 0
        case .yesterday: return 1
        case .previous7Days: return 2
        case .previous30Days: return 3
        case .month: return 4
        }
    }

    /// `items` grouped by day, newest group first, keeping their order within each group.
    public static func group<Item>(_ items: [Item], now: Date = Date(), calendar: Calendar = .current,
                                   date: (Item) -> Date) -> [DaySection<Item>] {
        var order: [DayGroup] = []
        var buckets: [DayGroup: [Item]] = [:]
        for item in items {
            let group = of(date(item), now: now, calendar: calendar)
            if buckets[group] == nil { order.append(group) }
            buckets[group, default: []].append(item)
        }
        return order.sorted().map { DaySection(group: $0, items: buckets[$0] ?? []) }
    }
}

public struct DaySection<Item>: Identifiable {
    public var group: DayGroup
    public var items: [Item]
    public var id: DayGroup { group }
}

/// A document cut at its "## " headings: what comes before the first, then each section.
public struct MarkdownSection: Equatable, Sendable {
    public var title: String
    public var blocks: [MarkdownBlock]
}

extension MarkdownBlocks {
    /// Splits at level 1 and 2 headings. A section that starts by repeating its own title (the meeting
    /// summary's "### Summary" under "## Summary") loses the repeat.
    public static func sections(_ blocks: [MarkdownBlock]) -> (preamble: [MarkdownBlock], sections: [MarkdownSection]) {
        var preamble: [MarkdownBlock] = []
        var sections: [MarkdownSection] = []
        for block in blocks {
            if case let .heading(level, text) = block, level <= 2 {
                sections.append(MarkdownSection(title: text, blocks: []))
                continue
            }
            guard !sections.isEmpty else {
                preamble.append(block)
                continue
            }
            if sections[sections.count - 1].blocks.isEmpty, case let .heading(_, text) = block,
               text.caseInsensitiveCompare(sections[sections.count - 1].title) == .orderedSame {
                continue
            }
            sections[sections.count - 1].blocks.append(block)
        }
        return (preamble, sections)
    }
}
