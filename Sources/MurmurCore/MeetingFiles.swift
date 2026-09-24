import Foundation

/// A saved meeting's notes, for the Library.
public struct MeetingFile: Identifiable, Equatable, Sendable {
    public var url: URL
    public var date: Date
    public var title: String
    /// The Summary section, or empty while the meeting is still going.
    public var summary: String
    /// The whole file.
    public var markdown: String

    public var id: URL { url }

    /// Reads a meeting file written by `MeetingNotes.markdown`. Nil for anything else.
    public static func parse(_ text: String, url: URL, fallbackDate: Date) -> MeetingFile? {
        guard text.hasPrefix("# "), text.contains("## Transcript") else { return nil }
        let title = String(text.dropFirst(2).prefix { !$0.isNewline }).trimmingCharacters(in: .whitespaces)
        var summary = ""
        if let start = text.range(of: "## Summary\n") {
            let rest = text[start.upperBound...]
            let end = rest.range(of: "\n## ")?.lowerBound ?? rest.endIndex
            summary = rest[..<end].trimmingCharacters(in: .whitespacesAndNewlines)
            if summary == MeetingNotes.summaryPlaceholder { summary = "" }
        }
        return MeetingFile(url: url, date: date(fromFileName: url.lastPathComponent) ?? fallbackDate,
                           title: title.isEmpty ? "Meeting" : title, summary: summary, markdown: text)
    }

    /// "2026-09-23 1530 Meeting.md" (or "… Meeting 2.md") → that time, in the local time zone.
    static func date(fromFileName name: String, timeZone: TimeZone = .current) -> Date? {
        let scalars = Array(name)
        guard scalars.count >= 15 else { return nil }
        let digits = String(scalars[0..<15])
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd HHmm"
        return formatter.date(from: digits)
    }

    /// Words of the whole file, for search.
    public func matches(_ query: String) -> Bool {
        let q = query.trimmingCharacters(in: .whitespaces)
        return q.isEmpty || markdown.range(of: q, options: [.caseInsensitive, .diacriticInsensitive]) != nil
    }
}

/// The meeting notes folder, read-only.
public struct MeetingStore: Sendable {
    public var folder: URL

    public init(folder: URL) { self.folder = folder }

    public init(config: MeetingConfig) {
        self.init(folder: URL(fileURLWithPath: AppPaths.expandTilde(config.folder), isDirectory: true))
    }

    /// Every meeting, newest first.
    public func list() -> [MeetingFile] {
        let fm = FileManager.default
        let files = (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        return files.filter { $0.pathExtension == "md" }
            .compactMap { url in
                guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
                let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                return MeetingFile.parse(text, url: url, fallbackDate: modified ?? Date(timeIntervalSince1970: 0))
            }
            .sorted { $0.date > $1.date }
    }
}

/// Decides when to offer meeting notes: another app has held the microphone for a few seconds
/// while a meeting app is running. Offers once per call, never while Murmur itself is recording.
public struct CallDetector: Sendable {
    /// Apps whose microphone use means a call. Browsers count too (Meet, Teams on the web).
    public static let meetingApps: [String: String] = [
        "us.zoom.xos": "Zoom",
        "com.microsoft.teams2": "Microsoft Teams",
        "com.microsoft.teams": "Microsoft Teams",
        "com.apple.FaceTime": "FaceTime",
        "com.cisco.webexmeetingsapp": "Webex",
        "Cisco-Systems.Spark": "Webex",
        "com.tinyspeck.slackmacgap": "Slack",
        "com.hnc.Discord": "Discord",
        "com.google.Chrome": "your browser",
        "com.apple.Safari": "your browser",
        "company.thebrowser.Browser": "your browser",
        "org.mozilla.firefox": "your browser",
        "com.microsoft.edgemac": "your browser",
        "com.brave.Browser": "your browser",
    ]

    /// How long the microphone must stay busy before offering, so a quick voice memo does not count.
    public var settle: TimeInterval
    private var busySince: Date?
    private var offered = false

    public init(settle: TimeInterval = 5) { self.settle = settle }

    /// - Parameters:
    ///   - micBusy: some app other than Murmur is using a microphone.
    ///   - runningApps: bundle IDs of running apps, frontmost first.
    ///   - murmurRecording: Murmur is dictating or already taking meeting notes.
    /// - Returns: the app to name in the offer, once per call.
    public mutating func update(micBusy: Bool, runningApps: [String], murmurRecording: Bool, now: Date = Date()) -> String? {
        guard micBusy else {
            busySince = nil
            offered = false
            return nil
        }
        if murmurRecording {
            // A call Murmur is already part of, or dictation holding the mic: never offer for it.
            offered = true
            return nil
        }
        let since = busySince ?? now
        busySince = since
        guard !offered, now.timeIntervalSince(since) >= settle,
              let app = runningApps.lazy.compactMap({ Self.meetingApps[$0] }).first else { return nil }
        offered = true
        return app
    }
}

/// What "Copy Diagnostics" puts on the clipboard: settings and state, never anything dictated.
public struct Diagnostics: Sendable {
    public private(set) var lines: [(String, String)] = []

    public init() {}

    public mutating func add(_ label: String, _ value: String?) {
        let text = (value?.isEmpty == false ? value! : "—")
        lines.append((label, Self.redactHome(text)))
    }

    public var text: String {
        let width = lines.map(\.0.count).max() ?? 0
        return "Murmur diagnostics\n" + lines.map { label, value in
            label + ":" + String(repeating: " ", count: width - label.count + 1) + value
        }.joined(separator: "\n") + "\n"
    }

    /// "/Users/kade/…" → "~/…", so the report does not carry a user name.
    static func redactHome(_ text: String, home: String = NSHomeDirectory()) -> String {
        guard !home.isEmpty, home != "/" else { return text }
        return text.replacingOccurrences(of: home, with: "~")
    }
}
