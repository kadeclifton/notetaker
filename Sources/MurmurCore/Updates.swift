import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// A release version like "0.1.3" (a leading "v" is fine). Compared number by number.
public struct ReleaseVersion: Comparable, Sendable, CustomStringConvertible {
    public let parts: [Int]

    public init?(_ string: String) {
        var text = string.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("v") || text.hasPrefix("V") { text.removeFirst() }
        // "0.2.0-beta" compares as 0.2.0; releases here have no suffixes.
        let core = text.split(separator: "-", maxSplits: 1).first.map(String.init) ?? text
        let parts = core.split(separator: ".").map { Int($0) }
        guard !parts.isEmpty, parts.allSatisfy({ $0 != nil }) else { return nil }
        self.parts = parts.compactMap { $0 }
    }

    public var description: String { parts.map(String.init).joined(separator: ".") }

    public static func < (lhs: ReleaseVersion, rhs: ReleaseVersion) -> Bool {
        for i in 0..<max(lhs.parts.count, rhs.parts.count) {
            let a = i < lhs.parts.count ? lhs.parts[i] : 0
            let b = i < rhs.parts.count ? rhs.parts[i] : 0
            if a != b { return a < b }
        }
        return false
    }

    public static func == (lhs: ReleaseVersion, rhs: ReleaseVersion) -> Bool { !(lhs < rhs) && !(rhs < lhs) }
}

/// The newest published release and its app download.
public struct ReleaseInfo: Equatable, Sendable {
    public var version: ReleaseVersion
    public var tag: String
    public var page: URL
    public var download: URL
    public var notes: String

    public static func == (lhs: ReleaseInfo, rhs: ReleaseInfo) -> Bool { lhs.tag == rhs.tag && lhs.download == rhs.download }
}

public enum UpdateError: Error, CustomStringConvertible, Equatable {
    case badRepository(String)
    case noRelease
    case noDownload(String)
    case untrustedDownload(String)

    public var description: String {
        switch self {
        case let .badRepository(repo): return "updates.repository \"\(repo)\" is not \"owner/name\"."
        case .noRelease: return "No published release was found."
        case let .noDownload(tag): return "Release \(tag) has no Murmur zip to download."
        case let .untrustedDownload(url): return "The update's download (\(url)) is not an https GitHub address."
        }
    }
}

/// Asks GitHub for the latest release. Public repositories need no account or key.
public struct UpdateChecker: Sendable {
    public var repository: String
    public var client: HTTPClient

    public init(repository: String, client: HTTPClient = URLSessionHTTPClient()) {
        self.repository = repository
        self.client = client
    }

    public func latest() async throws -> ReleaseInfo {
        let parts = repository.split(separator: "/")
        guard parts.count == 2, parts.allSatisfy({ !$0.isEmpty && !$0.contains(" ") }),
              let url = URL(string: "https://api.github.com/repos/\(repository)/releases/latest") else {
            throw UpdateError.badRepository(repository)
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Murmur", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await client.send(request)
        if response.statusCode == 404 { throw UpdateError.noRelease }
        guard (200..<300).contains(response.statusCode) else {
            throw APIError(service: "GitHub", status: response.statusCode, message: HTTP.errorMessage(from: data))
        }
        return try Self.parse(data)
    }

    /// Whether `release` is newer than the running version.
    public static func isNewer(_ release: ReleaseInfo, than current: String) -> Bool {
        guard let running = ReleaseVersion(current) else { return false }
        return running < release.version
    }

    static func parse(_ data: Data) throws -> ReleaseInfo {
        struct Release: Decodable {
            struct Asset: Decodable {
                let name: String
                let browser_download_url: URL
            }
            let tag_name: String
            let html_url: URL
            let body: String?
            let draft: Bool?
            let prerelease: Bool?
            let assets: [Asset]
        }
        let release = try JSONDecoder().decode(Release.self, from: data)
        guard release.draft != true, release.prerelease != true,
              let version = ReleaseVersion(release.tag_name) else { throw UpdateError.noRelease }
        // The workflow publishes "Murmur-<tag>.zip"; accept any Murmur zip in case it is renamed.
        let zips = release.assets.filter { $0.name.hasSuffix(".zip") && $0.name.lowercased().hasPrefix("murmur") }
        guard let asset = zips.first(where: { $0.name == "Murmur-\(release.tag_name).zip" }) ?? zips.first else {
            throw UpdateError.noDownload(release.tag_name)
        }
        // Belt and braces: the app is verified after download too, but never fetch it over plain http
        // or from anywhere but GitHub.
        guard NetworkSafety.isGitHubDownload(asset.browser_download_url) else {
            throw UpdateError.untrustedDownload(asset.browser_download_url.absoluteString)
        }
        return ReleaseInfo(version: version, tag: release.tag_name, page: release.html_url,
                           download: asset.browser_download_url, notes: release.body ?? "")
    }
}
