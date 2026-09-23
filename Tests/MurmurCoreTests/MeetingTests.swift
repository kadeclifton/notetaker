import XCTest
@testable import MurmurCore

struct FakeChat: ChatModel {
    var name = "fake"
    var reply: @Sendable (String, String) async throws -> String
    func complete(system: String, user: String, maxTokens: Int, timeout: TimeInterval) async throws -> String {
        try await reply(system, user)
    }
}

final class ChatLog: @unchecked Sendable {
    private let lock = NSLock()
    private var _calls: [(system: String, user: String)] = []
    var calls: [(system: String, user: String)] { lock.withLock { _calls } }
    func record(_ system: String, _ user: String) { lock.withLock { _calls.append((system, user)) } }
}

final class AudioChunkerTests: XCTestCase {
    func tone(_ seconds: Double, level: Float = 0.2) -> [Float] {
        (0..<Int(seconds * 16_000)).map { sin(Float($0) / 5) * level }
    }

    func testCutsAtThePauseInTheLastThird() {
        var chunker = AudioChunker(target: 30)
        // 25 s of speech, a 0.5 s pause, then more speech.
        let audio = tone(25) + [Float](repeating: 0, count: 8_000) + tone(10)
        let chunks = chunker.append(audio)
        XCTAssertEqual(chunks.count, 1)
        XCTAssertEqual(chunks[0].start, 0)
        XCTAssertEqual(chunks[0].duration, 25.25, accuracy: 0.2, "cut inside the pause")
        let rest = chunker.flush()
        XCTAssertEqual(rest?.start ?? 0, chunks[0].duration, accuracy: 0.001)
        XCTAssertEqual((rest?.duration ?? 0) + chunks[0].duration, 35.5, accuracy: 0.001)
        XCTAssertNil(chunker.flush())
    }

    func testKeepsTimeAcrossManyAppends() {
        var chunker = AudioChunker(target: 10)
        var chunks: [AudioChunk] = []
        for _ in 0..<25 { chunks += chunker.append(tone(1)) }
        XCTAssertGreaterThanOrEqual(chunks.count, 2)
        for pair in zip(chunks, chunks.dropFirst()) {
            XCTAssertEqual(pair.1.start, pair.0.start + pair.0.duration, accuracy: 0.001)
        }
        XCTAssertLessThan(chunker.pending, 10)
    }
}

final class MeetingTranscriptTests: XCTestCase {
    func testSegmentsAreOrderedAndMergedIntoTurns() {
        var transcript = MeetingTranscript()
        transcript.add([TimedText(start: 0, end: 2, text: " Hi everyone."), TimedText(start: 3, end: 5, text: " [BLANK_AUDIO]")],
                       chunkStart: 0, speaker: .others)
        transcript.add([TimedText(start: 1, end: 3, text: " Morning!")], chunkStart: 5, speaker: .me)
        transcript.add([TimedText(start: 0, end: 4, text: " Let's start with the roadmap.")], chunkStart: 30, speaker: .others)
        transcript.add([TimedText(start: 5, end: 6, text: " First item is Q4.")], chunkStart: 30, speaker: .others)
        XCTAssertEqual(transcript.segments.map(\.start), [0, 6, 30, 35])
        XCTAssertEqual(transcript.plainText(), """
        [00:00] Others: Hi everyone.
        [00:06] Me: Morning!
        [00:30] Others: Let's start with the roadmap. First item is Q4.
        """)
        XCTAssertEqual(transcript.markdown(), """
        **[00:00] Others:** Hi everyone.

        **[00:06] Me:** Morning!

        **[00:30] Others:** Let's start with the roadmap. First item is Q4.
        """)
    }

    func testMicEchoOfTheCallIsDropped() {
        let transcript = MeetingTranscript(segments: [
            MeetingSegment(start: 10, speaker: .others, text: "We should ship the beta on Friday."),
            MeetingSegment(start: 11, speaker: .me, text: "we should ship the beta Friday"),
            MeetingSegment(start: 14, speaker: .me, text: "Sounds good, I'll write the release notes."),
            MeetingSegment(start: 15, speaker: .me, text: "Yeah."),
        ])
        XCTAssertEqual(transcript.withoutEcho().map(\.text),
                       ["We should ship the beta on Friday.", "Sounds good, I'll write the release notes.", "Yeah."])
    }

    func testClock() {
        XCTAssertEqual(MeetingTranscript.clock(65), "01:05")
        XCTAssertEqual(MeetingTranscript.clock(3725), "1:02:05")
    }

    func testNotesFile() {
        let transcript = MeetingTranscript(segments: [MeetingSegment(start: 0, speaker: .me, text: "Hello.")])
        let notes = MeetingNotes.markdown(title: "Meeting, Sep 23", details: "**Duration:** 1 min", summary: nil, transcript: transcript)
        XCTAssertEqual(notes, """
        # Meeting, Sep 23

        **Duration:** 1 min

        ## Summary

        \(MeetingNotes.summaryPlaceholder)

        ## Transcript

        **[00:00] Me:** Hello.

        """)
        let date = Date(timeIntervalSince1970: 1_790_350_200) // 2026-09-25 15:30 UTC
        XCTAssertEqual(MeetingNotes.fileName(for: date, timeZone: TimeZone(identifier: "UTC")!), "2026-09-25 1530 Meeting.md")
    }

    func testAvailableURLNeverOverwrites() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let date = Date()
        let first = MeetingNotes.availableURL(in: dir, for: date)
        try Data().write(to: first)
        let second = MeetingNotes.availableURL(in: dir, for: date)
        XCTAssertNotEqual(first, second)
        XCTAssertTrue(second.lastPathComponent.hasSuffix(" Meeting 2.md"))
    }
}

final class MeetingSummarizerTests: XCTestCase {
    let transcript = MeetingTranscript(segments: [
        MeetingSegment(start: 0, speaker: .others, text: "Can you send the deck by Friday?"),
        MeetingSegment(start: 5, speaker: .me, text: "Yes, I'll send it Thursday."),
    ])

    func testShortMeetingIsOneCall() async throws {
        let log = ChatLog()
        let summarizer = MeetingSummarizer(chat: FakeChat { system, user in
            log.record(system, user)
            return "### Summary\n- Deck due Thursday."
        })
        let notes = try await summarizer.summarize(transcript)
        XCTAssertEqual(notes, "### Summary\n- Deck due Thursday.")
        XCTAssertEqual(log.calls.count, 1)
        XCTAssertTrue(log.calls[0].system.contains("### Action items"))
        XCTAssertEqual(log.calls[0].user, "<transcript>\n[00:00] Others: Can you send the deck by Friday?\n[00:05] Me: Yes, I'll send it Thursday.\n</transcript>")
    }

    func testLongMeetingIsSummarizedInParts() async throws {
        let log = ChatLog()
        let summarizer = MeetingSummarizer(chat: FakeChat { system, user in
            log.record(system, user)
            return "notes"
        }, wordsPerPart: 8)
        _ = try await summarizer.summarize(transcript)
        XCTAssertEqual(log.calls.count, 3, "two parts, then one combine")
        XCTAssertTrue(log.calls[0].user.hasPrefix("Part 1 of 2:"))
        XCTAssertTrue(log.calls[2].user.contains("Notes on part 2:\nnotes"))
        XCTAssertEqual(log.calls[2].system, MeetingSummarizer.notesSystem)
    }

    func testEmptyTranscriptNeedsNoModel() async throws {
        let summarizer = MeetingSummarizer(chat: FakeChat { _, _ in XCTFail("no call"); return "" })
        let notes = try await summarizer.summarize(MeetingTranscript())
        XCTAssertEqual(notes, "")
    }
}
