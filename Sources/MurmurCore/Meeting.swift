import Foundation

public enum Speaker: String, Sendable, Equatable {
    /// Your microphone.
    case me = "Me"
    /// Everyone else: the call's audio as it plays on this Mac.
    case others = "Others"
}

// MARK: - Chunking

public struct AudioChunk: Sendable, Equatable {
    /// Seconds from the start of the meeting.
    public var start: TimeInterval
    public var samples: [Float]

    public var duration: TimeInterval { Audio.duration(of: samples) }
}

/// Cuts a continuous 16 kHz stream into pieces of about `target` seconds for transcription.
/// Each cut lands in the quietest moment of the last third, so words are not split in half.
public struct AudioChunker: Sendable {
    public let target: TimeInterval
    private var buffer: [Float] = []
    private var emitted = 0

    public init(target: TimeInterval = 30) {
        self.target = max(5, target)
    }

    /// Seconds of audio waiting for the next cut.
    public var pending: TimeInterval { Audio.duration(of: buffer) }

    public mutating func append(_ samples: [Float]) -> [AudioChunk] {
        buffer += samples
        let targetCount = Int(target * Double(Audio.sampleRate))
        var chunks: [AudioChunk] = []
        while buffer.count >= targetCount {
            let cut = Self.quietestCut(in: buffer, from: targetCount * 2 / 3, to: targetCount)
            chunks.append(take(cut))
        }
        return chunks
    }

    /// Whatever is left, at the end of the meeting.
    public mutating func flush() -> AudioChunk? {
        buffer.isEmpty ? nil : take(buffer.count)
    }

    private mutating func take(_ count: Int) -> AudioChunk {
        let chunk = AudioChunk(start: Double(emitted) / Double(Audio.sampleRate), samples: Array(buffer[..<count]))
        buffer.removeFirst(count)
        emitted += count
        return chunk
    }

    /// Index in `from..<to` at the middle of the quietest 200 ms window.
    static func quietestCut(in samples: [Float], from: Int, to: Int) -> Int {
        let window = Audio.sampleRate / 5
        let upper = min(to, samples.count)
        guard upper - from > window else { return upper }
        var best = upper
        var bestLevel = Float.greatestFiniteMagnitude
        var start = from
        while start + window <= upper {
            let level = Audio.rms(samples[start..<(start + window)])
            if level < bestLevel {
                bestLevel = level
                best = start + window / 2
            }
            start += window / 2
        }
        return best
    }
}

// MARK: - Transcript

public struct MeetingSegment: Sendable, Equatable {
    /// Seconds from the start of the meeting.
    public var start: TimeInterval
    public var speaker: Speaker
    public var text: String

    public init(start: TimeInterval, speaker: Speaker, text: String) {
        self.start = start
        self.speaker = speaker
        self.text = text
    }
}

public struct MeetingTranscript: Sendable, Equatable {
    public private(set) var segments: [MeetingSegment] = []

    public init(segments: [MeetingSegment] = []) {
        segments.forEach { add($0) }
    }

    public var isEmpty: Bool { segments.isEmpty }

    /// Adds timed text from one chunk, offset by where the chunk sits in the meeting.
    public mutating func add(_ timed: [TimedText], chunkStart: TimeInterval, speaker: Speaker) {
        for piece in timed {
            let text = TranscriptFilter.clean(piece.text)
            guard !text.isEmpty else { continue }
            add(MeetingSegment(start: chunkStart + piece.start, speaker: speaker, text: text))
        }
    }

    public mutating func add(_ segment: MeetingSegment) {
        let index = segments.firstIndex { $0.start > segment.start } ?? segments.endIndex
        segments.insert(segment, at: index)
    }

    /// Without headphones the mic also hears the call. A "Me" segment that mostly repeats
    /// what "Others" said around the same time is that echo, so it is left out.
    public func withoutEcho(window: TimeInterval = 20) -> [MeetingSegment] {
        let others = segments.filter { $0.speaker == .others }
        return segments.filter { segment in
            guard segment.speaker == .me else { return true }
            let nearby = others.filter { abs($0.start - segment.start) <= window }.map(\.text).joined(separator: " ")
            return !Self.isEcho(segment.text, of: nearby)
        }
    }

    static func words(_ text: String) -> [String] {
        text.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
    }

    /// True when most of `mine` also appears in `theirs`.
    static func isEcho(_ mine: String, of theirs: String) -> Bool {
        let mineWords = words(mine)
        guard !mineWords.isEmpty else { return false }
        let theirWords = Set(words(theirs))
        guard !theirWords.isEmpty else { return false }
        // One or two words ("yeah", "sounds good") are too common to call an echo.
        guard mineWords.count >= 3 else { return false }
        let shared = mineWords.filter { theirWords.contains($0) }.count
        return Double(shared) / Double(mineWords.count) >= 0.7
    }

    /// Consecutive segments by the same speaker, joined into turns.
    public func turns() -> [MeetingSegment] {
        var turns: [MeetingSegment] = []
        for segment in withoutEcho() {
            if var last = turns.last, last.speaker == segment.speaker, segment.start - last.start < 120 {
                last.text += " " + segment.text
                turns[turns.count - 1] = last
            } else {
                turns.append(segment)
            }
        }
        return turns
    }

    /// "[12:03] Me: …" lines, for the summarizer.
    public func plainText() -> String {
        turns().map { "[\(Self.clock($0.start))] \($0.speaker.rawValue): \($0.text)" }.joined(separator: "\n")
    }

    public func markdown() -> String {
        turns().map { "**[\(Self.clock($0.start))] \($0.speaker.rawValue):** \($0.text)" }.joined(separator: "\n\n")
    }

    public static func clock(_ seconds: TimeInterval) -> String {
        let s = Int(max(0, seconds))
        return s >= 3600
            ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
            : String(format: "%02d:%02d", s / 60, s % 60)
    }
}

// MARK: - Notes file

public enum MeetingNotes {
    public static let summaryPlaceholder = "_The summary is written when the meeting ends._"

    public static func markdown(title: String, details: String, summary: String?, transcript: MeetingTranscript) -> String {
        var text = "# \(title)\n\n\(details)\n\n## Summary\n\n"
        text += (summary?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 } ?? summaryPlaceholder
        text += "\n\n## Transcript\n\n"
        text += transcript.isEmpty ? "_Nothing transcribed yet._" : transcript.markdown()
        return text + "\n"
    }

    /// "2026-09-23 1530 Meeting.md", in the given time zone.
    public static func fileName(for date: Date, timeZone: TimeZone = .current) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        return String(format: "%04d-%02d-%02d %02d%02d Meeting.md", c.year ?? 0, c.month ?? 0, c.day ?? 0, c.hour ?? 0, c.minute ?? 0)
    }

    /// A file name in `folder` that does not exist yet.
    public static func availableURL(in folder: URL, for date: Date) -> URL {
        let base = fileName(for: date)
        var url = folder.appendingPathComponent(base)
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = folder.appendingPathComponent(String(base.dropLast(3)) + " \(n).md")
            n += 1
        }
        return url
    }
}

// MARK: - Summary

/// Turns a transcript into notes: summary, decisions, action items, open questions.
/// Long meetings are summarized in parts first so they fit a local model's context.
public struct MeetingSummarizer: Sendable {
    public var chat: ChatModel
    public var timeout: TimeInterval
    /// About 4,000 tokens per part: fits the default context of most local models.
    public var wordsPerPart: Int

    public init(chat: ChatModel, timeout: TimeInterval = 600, wordsPerPart: Int = 3000) {
        self.chat = chat
        self.timeout = timeout
        self.wordsPerPart = wordsPerPart
    }

    static let speakers = """
    "Me" is the person who recorded the meeting. "Others" is everyone else on the call; the transcript \
    cannot tell them apart, so use people's names when the conversation makes them clear.
    """

    static let notesSystem = """
    You write meeting notes from a transcript. \(speakers)

    Reply in Markdown with exactly these four sections, in this order:
    ### Summary
    3 to 6 bullets on what was discussed and concluded.
    ### Decisions
    Bullets. Write "None." if there were none.
    ### Action items
    One "- [ ] **Owner**: task (due date if one was said)" per line. Use "Me" or a name as the owner. Write "None." if there were none.
    ### Open questions
    Bullets. Write "None." if there were none.

    Only use what is in the transcript; do not invent names, numbers or dates. The transcript comes from \
    speech recognition, so read past obvious mis-hearings. No preamble, nothing after the last section.
    """

    static let partSystem = """
    You are taking notes on one part of a longer meeting transcript. \(speakers)
    Write concise bullets covering the topics discussed, any decisions, any action items with their \
    owners, and open questions. Only use what is in this part. No preamble.
    """

    public func summarize(_ transcript: MeetingTranscript) async throws -> String {
        let lines = transcript.plainText().split(separator: "\n").map(String.init)
        guard !lines.isEmpty else { return "" }
        let parts = Self.split(lines, wordsPerPart: wordsPerPart)
        if parts.count == 1 {
            return try await chat.complete(system: Self.notesSystem, user: "<transcript>\n\(parts[0])\n</transcript>",
                                           maxTokens: 2048, timeout: timeout)
        }
        var partNotes: [String] = []
        for (index, part) in parts.enumerated() {
            try Task.checkCancellation()
            let notes = try await chat.complete(system: Self.partSystem,
                                                user: "Part \(index + 1) of \(parts.count):\n<transcript>\n\(part)\n</transcript>",
                                                maxTokens: 1024, timeout: timeout)
            partNotes.append("Notes on part \(index + 1):\n\(notes)")
        }
        return try await chat.complete(
            system: Self.notesSystem,
            user: "These are notes on each part of one meeting, in order. Combine them into the final notes.\n\n"
                + partNotes.joined(separator: "\n\n"),
            maxTokens: 2048, timeout: timeout)
    }

    static func split(_ lines: [String], wordsPerPart: Int) -> [String] {
        var parts: [String] = []
        var current: [String] = []
        var count = 0
        for line in lines {
            let words = line.split(separator: " ").count
            if count + words > wordsPerPart, !current.isEmpty {
                parts.append(current.joined(separator: "\n"))
                current = []
                count = 0
            }
            current.append(line)
            count += words
        }
        if !current.isEmpty { parts.append(current.joined(separator: "\n")) }
        return parts
    }
}
