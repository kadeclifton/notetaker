import Foundation

/// murmur:// links: what the desktop widget's buttons open. Starting a meeting this way also opens
/// its live transcript, so a link can never record without it showing.
public enum MurmurLink: Equatable, Sendable {
    case startMeeting
    case stopMeeting
    /// The meeting being recorded, or the meeting notes in Library when there is none.
    case meeting
    case library(meetings: Bool)
    /// A Settings page by name ("speech"), or the last one open.
    case settings(page: String?)

    public static let scheme = "murmur"

    public static func parse(_ url: URL) -> MurmurLink? {
        guard url.scheme?.lowercased() == scheme else { return nil }
        let parts = ([url.host ?? ""] + url.pathComponents)
            .filter { !$0.isEmpty && $0 != "/" }
            .map { $0.lowercased() }
        guard let first = parts.first else { return nil }
        let second = parts.dropFirst().first
        switch first {
        case "meeting":
            switch second {
            case "start": return .startMeeting
            case "stop": return .stopMeeting
            case nil: return .meeting
            default: return nil
            }
        case "library": return .library(meetings: second == "meetings")
        case "settings": return .settings(page: second)
        default: return nil
        }
    }

    public var url: URL {
        let path: String
        switch self {
        case .startMeeting: path = "meeting/start"
        case .stopMeeting: path = "meeting/stop"
        case .meeting: path = "meeting"
        case let .library(meetings): path = meetings ? "library/meetings" : "library"
        case let .settings(page): path = page.map { "settings/\($0)" } ?? "settings"
        }
        return URL(string: "\(Self.scheme)://\(path)")!
    }
}
