import Foundation

/// Murmur's own recent problems, kept on this Mac for Copy Diagnostics: when and what went wrong,
/// never anything that was dictated. The newest `limit` are kept.
public struct ErrorLog: Codable, Equatable, Sendable {
    public struct Entry: Codable, Equatable, Sendable {
        public var date: Date
        public var message: String
    }

    public private(set) var entries: [Entry] = []
    public static let limit = 20

    public init() {}

    public mutating func add(_ message: String, at date: Date = Date(), home: String = NSHomeDirectory()) {
        var text = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        if !home.isEmpty, home != "/" { text = text.replacingOccurrences(of: home, with: "~") }
        if text.count > 300 { text = String(text.prefix(297)) + "…" }
        // The same problem again moves to the top instead of filling the log.
        entries.removeAll { $0.message == text }
        entries.insert(Entry(date: date, message: text), at: 0)
        if entries.count > Self.limit { entries.removeLast(entries.count - Self.limit) }
    }

    /// "2026-09-28 14:03  whisper-server stopped while starting: …", newest first.
    public func lines(timeZone: TimeZone = .current) -> [String] {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return entries.map { "\(formatter.string(from: $0.date))  \($0.message)" }
    }
}
