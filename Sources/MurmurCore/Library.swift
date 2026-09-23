import Foundation

/// One composed piece and what was said to make it.
public struct LibraryEntry: Identifiable, Equatable, Sendable {
    public var id: UUID
    public var created: Date
    public var style: ComposeStyle
    /// The app it was written for.
    public var app: String?
    /// The model that wrote it.
    public var model: String?
    /// The finished writing. Empty if it was never written (no model, or cancelled).
    public var text: String
    /// What Whisper heard.
    public var transcript: String
    /// Where it is saved. Set by `LibraryStore`.
    public var fileURL: URL?

    public init(id: UUID = UUID(), created: Date = Date(), style: ComposeStyle, app: String? = nil, model: String? = nil,
                text: String, transcript: String, fileURL: URL? = nil) {
        self.id = id
        self.created = created
        self.style = style
        self.app = app
        self.model = model
        self.text = text
        self.transcript = transcript
        self.fileURL = fileURL
    }

    /// The first few words of the first real line, without Markdown marks.
    public var title: String {
        let source = text.isEmpty ? transcript : text
        let line = source.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty && !$0.lowercased().hasPrefix("subject:") } ?? ""
        let plain = line.drop { "#-*>• ".contains($0) }.replacingOccurrences(of: "**", with: "")
        let words = plain.split(separator: " ")
        let title = words.prefix(8).joined(separator: " ")
        guard !title.isEmpty else { return "Untitled" }
        return words.count > 8 ? title + "…" : title
    }

    static let transcriptMarker = "<!-- murmur:what-i-said -->"
    static let transcriptHeading = "## What I said"

    /// A Markdown file with the details up top, the writing, then what was said.
    public var markdown: String {
        var front = ["id: \(id.uuidString)", "created: \(Self.dateFormatter.string(from: created))", "style: \(style.rawValue)"]
        if let app { front.append("app: \(Self.oneLine(app))") }
        if let model { front.append("model: \(Self.oneLine(model))") }
        return "---\n" + front.joined(separator: "\n") + "\n---\n\n"
            + text.trimmingCharacters(in: .whitespacesAndNewlines)
            + "\n\n" + Self.transcriptMarker + "\n" + Self.transcriptHeading + "\n\n"
            + transcript.trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
    }

    /// Reads `markdown` back. Nil for files that are not Murmur library entries.
    public static func parse(_ file: String, url: URL? = nil) -> LibraryEntry? {
        guard file.hasPrefix("---\n"), let end = file.range(of: "\n---\n", range: file.index(file.startIndex, offsetBy: 3)..<file.endIndex) else {
            return nil
        }
        var fields: [String: String] = [:]
        for line in file[file.index(file.startIndex, offsetBy: 4)..<end.lowerBound].split(separator: "\n") {
            guard let colon = line.firstIndex(of: ":") else { continue }
            fields[line[..<colon].trimmingCharacters(in: .whitespaces)] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        guard let id = fields["id"].flatMap(UUID.init(uuidString:)) else { return nil }
        let body = String(file[end.upperBound...])
        var text = body
        var transcript = ""
        if let marker = body.range(of: transcriptMarker, options: .backwards) {
            text = String(body[..<marker.lowerBound])
            transcript = String(body[marker.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            if transcript.hasPrefix(transcriptHeading) { transcript.removeFirst(transcriptHeading.count) }
        }
        return LibraryEntry(id: id,
                            created: fields["created"].flatMap(dateFormatter.date(from:)) ?? Date(timeIntervalSince1970: 0),
                            style: fields["style"].flatMap(ComposeStyle.init(rawValue:)) ?? .auto,
                            app: fields["app"], model: fields["model"],
                            text: text.trimmingCharacters(in: .whitespacesAndNewlines),
                            transcript: transcript.trimmingCharacters(in: .whitespacesAndNewlines),
                            fileURL: url)
    }

    /// "2026-09-23 14.05 Quick update on the launch.md"
    public var suggestedFileName: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH.mm"
        let safe = title.replacingOccurrences(of: "…", with: "")
            .map { "/:\\?%*|\"<>".contains($0) ? " " : $0 }
        let name = String(safe).split(separator: " ").joined(separator: " ").prefix(60)
        return "\(formatter.string(from: created)) \(name).md"
    }

    private static func oneLine(_ value: String) -> String {
        value.split(whereSeparator: \.isNewline).joined(separator: " ")
    }

    static let dateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()
}

/// Composed pieces as Markdown files in one folder, readable and editable in any editor.
public struct LibraryStore: Sendable {
    public var folder: URL

    public init(folder: URL) {
        self.folder = folder
    }

    public init(config: ComposeConfig) {
        self.init(folder: URL(fileURLWithPath: AppPaths.expandTilde(config.folder), isDirectory: true))
    }

    /// Writes the entry, to its existing file if it has one. Returns it with `fileURL` set.
    @discardableResult
    public func save(_ entry: LibraryEntry) throws -> LibraryEntry {
        var entry = entry
        let fm = FileManager.default
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        if entry.fileURL == nil || !fm.fileExists(atPath: entry.fileURL!.path) {
            entry.fileURL = availableURL(for: entry.suggestedFileName)
        }
        try Data(entry.markdown.utf8).write(to: entry.fileURL!, options: .atomic)
        return entry
    }

    /// Every entry in the folder, newest first.
    public func list() -> [LibraryEntry] {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "md" }
            .compactMap { url in
                (try? String(contentsOf: url, encoding: .utf8)).flatMap { LibraryEntry.parse($0, url: url) }
            }
            .sorted { $0.created > $1.created }
    }

    public func delete(_ entry: LibraryEntry) throws {
        guard let url = entry.fileURL else { return }
        try FileManager.default.removeItem(at: url)
    }

    private func availableURL(for name: String) -> URL {
        let base = (name as NSString).deletingPathExtension
        var url = folder.appendingPathComponent(name)
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = folder.appendingPathComponent("\(base) \(n).md")
            n += 1
        }
        return url
    }
}
