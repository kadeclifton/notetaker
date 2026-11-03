import XCTest
@testable import MurmurCore

final class MarkdownBlocksTests: XCTestCase {
    func testMeetingNotesFile() {
        var transcript = MeetingTranscript()
        transcript.add(MeetingSegment(start: 12, speaker: .me, text: "Can everyone hear me?"))
        transcript.add(MeetingSegment(start: 200, speaker: .others, text: "Yes, **loud** and clear."))
        let summary = """
        ### Summary
        - Planned the launch
          - Beta first
        ### Action items
        - [ ] **Me**: send the deck (Friday)
        - [x] **Sam**: book the room
        ### Open questions
        None.
        """
        let file = MeetingNotes.markdown(title: "Weekly sync", details: "Sep 23, 2026 · 25 min", summary: summary,
                                         transcript: transcript)
        XCTAssertEqual(MarkdownBlocks.parse(file), [
            .heading(level: 1, text: "Weekly sync"),
            .paragraph("Sep 23, 2026 · 25 min"),
            .heading(level: 2, text: "Summary"),
            .heading(level: 3, text: "Summary"),
            .bullet(text: "Planned the launch", indent: 0),
            .bullet(text: "Beta first", indent: 1),
            .heading(level: 3, text: "Action items"),
            .task(text: "**Me**: send the deck (Friday)", done: false, indent: 0),
            .task(text: "**Sam**: book the room", done: true, indent: 0),
            .heading(level: 3, text: "Open questions"),
            .paragraph("None."),
            .heading(level: 2, text: "Transcript"),
            .turn(time: "00:12", speaker: "Me", text: "Can everyone hear me?"),
            .turn(time: "03:20", speaker: "Others", text: "Yes, **loud** and clear."),
        ])
    }

    func testParagraphsQuotesRulesAndNumbers() {
        let text = """
        First line
        second line

        > quoted
        > more
        Plain again
        ---
        1. one
        2) two
        * star
        #NotAHeading
        **Bold:** not a turn
        """
        XCTAssertEqual(MarkdownBlocks.parse(text), [
            .paragraph("First line\nsecond line"),
            .quote("quoted\nmore"),
            .paragraph("Plain again"),
            .rule,
            .numbered(marker: "1.", text: "one", indent: 0),
            .numbered(marker: "2)", text: "two", indent: 0),
            .bullet(text: "star", indent: 0),
            .paragraph("#NotAHeading\n**Bold:** not a turn"),
        ])
    }

    func testSections() {
        let blocks = MarkdownBlocks.parse("""
        # Weekly sync
        Sep 23

        ## Summary
        ### Summary
        - one
        ### Decisions
        None.
        ## Transcript
        **[00:01] Me:** hi
        """)
        let (preamble, sections) = MarkdownBlocks.sections(blocks)
        XCTAssertEqual(preamble, [])
        XCTAssertEqual(sections.map(\.title), ["Weekly sync", "Summary", "Transcript"])
        XCTAssertEqual(sections[0].blocks, [.paragraph("Sep 23")])
        XCTAssertEqual(sections[1].blocks, [.bullet(text: "one", indent: 0), .heading(level: 3, text: "Decisions"), .paragraph("None.")])
        XCTAssertEqual(sections[2].blocks, [.turn(time: "00:01", speaker: "Me", text: "hi")])
        XCTAssertEqual(MarkdownBlocks.sections([.paragraph("a")]).preamble, [.paragraph("a")])
    }

    func testEmptyAndWindowsLineEndings() {
        XCTAssertEqual(MarkdownBlocks.parse(""), [])
        XCTAssertEqual(MarkdownBlocks.parse("# Hi\r\n\r\n- a\r\n"), [.heading(level: 1, text: "Hi"), .bullet(text: "a", indent: 0)])
    }
}

final class DayGroupTests: XCTestCase {
    var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        calendar.locale = Locale(identifier: "en_US")
        return calendar
    }

    func date(_ text: String) -> Date {
        let formatter = ISO8601DateFormatter()
        return formatter.date(from: text + "T12:00:00Z")!
    }

    func testGroups() {
        let now = date("2026-11-02")
        XCTAssertEqual(DayGroup.of(date("2026-11-02"), now: now, calendar: calendar), .today)
        XCTAssertEqual(DayGroup.of(date("2026-11-01"), now: now, calendar: calendar), .yesterday)
        XCTAssertEqual(DayGroup.of(date("2026-10-27"), now: now, calendar: calendar), .previous7Days)
        XCTAssertEqual(DayGroup.of(date("2026-10-10"), now: now, calendar: calendar), .previous30Days)
        let september = DayGroup.of(date("2026-09-15"), now: now, calendar: calendar)
        XCTAssertEqual(september.title(calendar: calendar, now: now), "September")
        let lastYear = DayGroup.of(date("2025-12-31"), now: now, calendar: calendar)
        XCTAssertEqual(lastYear.title(calendar: calendar, now: now), "December 2025")
        XCTAssertEqual(DayGroup.of(date("2026-11-03"), now: now, calendar: calendar), .today, "a clock running ahead is still today")
    }

    func testGroupKeepsOrderNewestGroupFirst() {
        let now = date("2026-11-02")
        let dates = ["2026-09-15", "2026-11-02", "2026-11-01", "2026-11-02", "2025-12-31"].map(date)
        let groups = DayGroup.group(Array(dates.enumerated()), now: now, calendar: calendar) { $0.element }
        XCTAssertEqual(groups.map { $0.group.title(calendar: calendar, now: now) }, ["Today", "Yesterday", "September", "December 2025"])
        XCTAssertEqual(groups[0].items.map(\.offset), [1, 3])
    }
}

final class WidgetSnapshotTests: XCTestCase {
    var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    func at(_ text: String) -> Date { ISO8601DateFormatter().date(from: text)! }

    func testTodayAndTheWeek() {
        var stats = UsageStats()
        stats.record(words: 100, spoken: 30, on: at("2026-11-02T09:00:00Z"), calendar: calendar)
        stats.record(words: 20, spoken: 6, on: at("2026-11-02T10:00:00Z"), calendar: calendar)
        stats.record(words: 50, spoken: 10, on: at("2026-10-30T10:00:00Z"), calendar: calendar)
        stats.record(words: 999, spoken: 10, on: at("2026-10-20T10:00:00Z"), calendar: calendar)
        let now = at("2026-11-02T18:00:00Z")
        let snapshot = WidgetSnapshot.make(stats: stats, lastMeeting: nil, meetingStarted: nil, hotkey: "fn", now: now, calendar: calendar)
        XCTAssertEqual(snapshot.wordsToday, 120)
        XCTAssertEqual(snapshot.dictationsToday, 2)
        XCTAssertEqual(snapshot.minutesSavedToday, 120 / UsageStats.typingWPM - 36.0 / 60, accuracy: 0.001)
        XCTAssertEqual(snapshot.week.map(\.words), [0, 0, 0, 50, 0, 0, 120])
        XCTAssertEqual(snapshot.week.first?.date, at("2026-10-27T00:00:00Z"))
        XCTAssertEqual(snapshot.wordsThisWeek, 170)
    }

    func testRollsOverAtMidnight() {
        var stats = UsageStats()
        stats.record(words: 40, spoken: 10, on: at("2026-11-01T09:00:00Z"), calendar: calendar)
        stats.record(words: 70, spoken: 10, on: at("2026-11-02T09:00:00Z"), calendar: calendar)
        let snapshot = WidgetSnapshot.make(stats: stats, lastMeeting: nil, meetingStarted: nil, hotkey: "fn",
                                           now: at("2026-11-02T23:00:00Z"), calendar: calendar)
        XCTAssertEqual(snapshot.rolledOver(to: at("2026-11-02T23:30:00Z"), calendar: calendar), snapshot)
        let tomorrow = snapshot.rolledOver(to: at("2026-11-03T00:05:00Z"), calendar: calendar)
        XCTAssertEqual(tomorrow.wordsToday, 0)
        XCTAssertEqual(tomorrow.dictationsToday, 0)
        XCTAssertEqual(tomorrow.week.map(\.words), [0, 0, 0, 0, 40, 70, 0])
        XCTAssertEqual(tomorrow.week.last?.date, at("2026-11-03T00:00:00Z"))
    }

    func testMeetingHighlightsAndRoundTrip() throws {
        let summary = """
        ### Summary
        - **Launch** moves to the 14th
          - detail left out
        - Beta goes to 40 customers first
        ### Decisions
        - Not a highlight
        ### Action items
        - [ ] **Me**: send the deck
        - [x] **Sam**: book the room
        - [ ] **Ana**: draft the post
        """
        let markdown = MeetingNotes.markdown(title: "Weekly sync", details: "", summary: summary, transcript: MeetingTranscript())
        let file = try XCTUnwrap(MeetingFile.parse(markdown, url: URL(fileURLWithPath: "/tmp/2026-11-02 0930 Meeting.md"),
                                                   fallbackDate: Date()))
        let meeting = WidgetSnapshot.Meeting(file: file)
        XCTAssertEqual(meeting.title, "Weekly sync")
        XCTAssertEqual(meeting.highlights, ["Launch moves to the 14th", "Beta goes to 40 customers first"])
        XCTAssertEqual(meeting.openActionItems, 2)

        let snapshot = WidgetSnapshot.make(stats: UsageStats(), lastMeeting: file, meetingStarted: at("2026-11-02T09:30:00Z"),
                                           hotkey: "fn", now: at("2026-11-02T10:00:00Z"), calendar: calendar)
        XCTAssertEqual(try WidgetSnapshot.decode(snapshot.encoded()), snapshot)
        XCTAssertEqual(WidgetSnapshot.sample().week.count, 7)
    }
}

final class MurmurLinkTests: XCTestCase {
    func testRoundTripsAndRejectsOthers() {
        let links: [MurmurLink] = [.startMeeting, .stopMeeting, .meeting, .library(meetings: false), .library(meetings: true),
                                   .settings(page: nil), .settings(page: "speech")]
        for link in links {
            XCTAssertEqual(MurmurLink.parse(link.url), link, link.url.absoluteString)
        }
        XCTAssertEqual(MurmurLink.parse(URL(string: "MURMUR://Meeting/Start")!), .startMeeting)
        XCTAssertNil(MurmurLink.parse(URL(string: "murmur://meeting/delete")!))
        XCTAssertNil(MurmurLink.parse(URL(string: "murmur://")!))
        XCTAssertNil(MurmurLink.parse(URL(string: "https://meeting/start")!))
        XCTAssertNil(MurmurLink.parse(URL(string: "murmur://format-disk")!))
    }
}

final class SnapshotCheckTests: XCTestCase {
    /// A width × height RGBA image filled by `pixel(x, y)`.
    func image(_ width: Int, _ height: Int, _ pixel: (Int, Int) -> (UInt8, UInt8, UInt8, UInt8)) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let (r, g, b, a) = pixel(x, y)
                let i = (y * width + x) * 4
                bytes[i] = r; bytes[i + 1] = g; bytes[i + 2] = b; bytes[i + 3] = a
            }
        }
        return bytes
    }

    func testEmptyWindowIsBlank() {
        let plain = image(400, 300) { _, _ in (236, 236, 236, 255) }
        let result = SnapshotCheck.analyze(rgba: plain, width: 400, height: 300)
        XCTAssertTrue(result.isBlank)
        XCTAssertEqual(result.colors, 1)
    }

    func testBlurredBackgroundIsBlankDespiteItsColors() {
        // A soft diagonal gradient with a little noise: like the desktop seen through a sidebar.
        let blurred = image(400, 300) { x, y in
            let base = 90 + (x + y) / 6 + (x * 7 + y * 13) % 5
            return (UInt8(base), UInt8(min(255, base + 20)), UInt8(min(255, base + 40)), 255)
        }
        let result = SnapshotCheck.analyze(rgba: blurred, width: 400, height: 300)
        XCTAssertTrue(result.isBlank, "\(result)")
        XCTAssertGreaterThan(result.colors, 20)
    }

    func testALineOfTextIsContent() {
        // Dark 1-px strokes, like a short label, on a light background.
        let text = image(400, 300) { x, y in
            let inLabel = (140...152).contains(y) && (40...200).contains(x) && (x % 4 == 0 || y == 146)
            return inLabel ? (30, 30, 30, 255) : (236, 236, 236, 255)
        }
        XCTAssertFalse(SnapshotCheck.analyze(rgba: text, width: 400, height: 300).isBlank)
    }

    func testRegionsAreCheckedOnTheirOwn() {
        // Content on the right half only: the left half (a sidebar with no rows) is blank.
        let rightOnly = image(400, 300) { x, y in
            x > 250 && y % 6 == 0 ? (20, 20, 20, 255) : (236, 236, 236, 255)
        }
        let left = SnapshotCheck.Region(x: 0, y: 0, width: 200, height: 300)
        let right = SnapshotCheck.Region(x: 200, y: 0, width: 999, height: 999)
        XCTAssertTrue(SnapshotCheck.analyze(rgba: rightOnly, width: 400, height: 300, region: left).isBlank)
        XCTAssertFalse(SnapshotCheck.analyze(rgba: rightOnly, width: 400, height: 300, region: right).isBlank)
        XCTAssertEqual(SnapshotCheck.clipped(right, width: 400, height: 300), SnapshotCheck.Region(x: 200, y: 0, width: 200, height: 300))
    }

    func testTransparentPillOutlineIsContent() {
        // A capsule edge against a transparent window.
        let pill = image(200, 48) { x, y in
            (8...40).contains(y) && (8...192).contains(x) ? (40, 40, 40, 230) : (0, 0, 0, 0)
        }
        XCTAssertFalse(SnapshotCheck.analyze(rgba: pill, width: 200, height: 48).isBlank)
    }
}
