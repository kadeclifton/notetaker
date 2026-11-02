import Foundation

/// What the desktop widget shows. Murmur writes it to the app group container whenever the numbers
/// change; the widget, which runs sandboxed in its own process, only reads it.
public struct WidgetSnapshot: Codable, Equatable, Sendable {
    public struct Day: Codable, Equatable, Sendable {
        /// Midnight at the start of the day.
        public var date: Date
        public var words: Int

        public init(date: Date, words: Int) {
            self.date = date
            self.words = words
        }
    }

    public struct Meeting: Codable, Equatable, Sendable {
        public var title: String
        public var date: Date
        /// The first few summary bullets, without Markdown marks.
        public var highlights: [String]
        /// Action items not ticked off yet.
        public var openActionItems: Int

        public init(title: String, date: Date, highlights: [String], openActionItems: Int) {
            self.title = title
            self.date = date
            self.highlights = highlights
            self.openActionItems = openActionItems
        }
    }

    public var updated: Date
    public var wordsToday: Int
    public var dictationsToday: Int
    public var minutesSavedToday: Double
    /// The last seven days, oldest first; today is last.
    public var week: [Day]
    public var lastMeeting: Meeting?
    /// When the meeting being recorded started; nil when none is.
    public var meetingStarted: Date?
    /// "fn", for the hint on an empty day.
    public var hotkey: String

    public static let fileName = "widget.json"
    /// The `Info.plist` key holding the app group both Murmur and its widget use. Release builds
    /// set it to "<Team ID>.com.github.kadeclifton.murmur"; builds without a Developer ID have none.
    public static let appGroupKey = "MurmurAppGroup"

    public var wordsThisWeek: Int { week.reduce(0) { $0 + $1.words } }

    public init(updated: Date, wordsToday: Int, dictationsToday: Int, minutesSavedToday: Double, week: [Day],
                lastMeeting: Meeting?, meetingStarted: Date?, hotkey: String) {
        self.updated = updated
        self.wordsToday = wordsToday
        self.dictationsToday = dictationsToday
        self.minutesSavedToday = minutesSavedToday
        self.week = week
        self.lastMeeting = lastMeeting
        self.meetingStarted = meetingStarted
        self.hotkey = hotkey
    }

    public static func make(stats: UsageStats, lastMeeting: MeetingFile?, meetingStarted: Date?, hotkey: String,
                            now: Date = Date(), calendar: Calendar = .current) -> WidgetSnapshot {
        let today = stats.summary(lastDays: 1, now: now, calendar: calendar)
        let week = (0..<7).reversed().map { offset -> Day in
            let date = calendar.date(byAdding: .day, value: -offset, to: calendar.startOfDay(for: now)) ?? now
            return Day(date: date, words: stats.summary(lastDays: 1, now: date, calendar: calendar).words)
        }
        return WidgetSnapshot(updated: now, wordsToday: today.words, dictationsToday: today.dictations,
                              minutesSavedToday: today.minutesSaved, week: week,
                              lastMeeting: lastMeeting.map(Meeting.init(file:)), meetingStarted: meetingStarted,
                              hotkey: hotkey)
    }

    /// As it should read at `now`: after midnight, today starts again at zero and the week moves on.
    public func rolledOver(to now: Date, calendar: Calendar = .current) -> WidgetSnapshot {
        guard !calendar.isDate(updated, inSameDayAs: now), now > updated else { return self }
        var copy = self
        copy.wordsToday = 0
        copy.dictationsToday = 0
        copy.minutesSavedToday = 0
        let start = calendar.startOfDay(for: now)
        copy.week = (0..<7).reversed().map { offset in
            let date = calendar.date(byAdding: .day, value: -offset, to: start) ?? start
            let words = week.first { calendar.isDate($0.date, inSameDayAs: date) }?.words ?? 0
            return Day(date: date, words: words)
        }
        return copy
    }

    /// Sample numbers for the widget gallery and while the real ones load.
    public static func sample(now: Date = Date(), calendar: Calendar = .current) -> WidgetSnapshot {
        let start = calendar.startOfDay(for: now)
        let words = [820, 1240, 460, 1530, 990, 1710, 1180]
        let week = words.enumerated().map { index, count in
            Day(date: calendar.date(byAdding: .day, value: index - 6, to: start) ?? start, words: count)
        }
        return WidgetSnapshot(
            updated: now, wordsToday: 1180, dictationsToday: 37, minutesSavedToday: 21, week: week,
            lastMeeting: Meeting(title: "Weekly sync", date: now.addingTimeInterval(-3 * 3600),
                                 highlights: ["Launch moves to the 14th", "Beta goes to 40 customers first"],
                                 openActionItems: 3),
            meetingStarted: nil, hotkey: "fn")
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        return try encoder.encode(self)
    }

    public static func decode(_ data: Data) throws -> WidgetSnapshot {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return try decoder.decode(WidgetSnapshot.self, from: data)
    }
}

extension WidgetSnapshot.Meeting {
    init(file: MeetingFile) {
        let blocks = MarkdownBlocks.parse(file.summary)
        // The "Summary" part's bullets come first in the notes; the other parts' bullets are left out.
        var highlights: [String] = []
        var section = ""
        var open = 0
        for block in blocks {
            switch block {
            case let .heading(_, text):
                section = text.lowercased()
            case let .bullet(text, 0) where section.isEmpty || section == "summary":
                highlights.append(Self.plain(text))
            case .task(_, false, _):
                open += 1
            default:
                break
            }
        }
        self.init(title: file.title, date: file.date, highlights: Array(highlights.prefix(3)), openActionItems: open)
    }

    static func plain(_ text: String) -> String {
        text.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "__", with: "")
            .trimmingCharacters(in: .whitespaces)
    }
}
