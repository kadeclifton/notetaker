import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// A release version like "0.1.3" or "0.2.2-beta.1" (a leading "v" is fine). Numbers compare one
/// by one; a pre-release (anything after "-") comes before its release: 0.2.2-beta.1 < 0.2.2-beta.2 < 0.2.2.
public struct ReleaseVersion: Comparable, Sendable, CustomStringConvertible {
    public let parts: [Int]
    /// "beta.1" → ["beta", "1"]; empty for a release.
    public let prerelease: [String]

    public init?(_ string: String) {
        var text = string.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("v") || text.hasPrefix("V") { text.removeFirst() }
        let pieces = text.split(separator: "-", maxSplits: 1).map(String.init)
        guard let core = pieces.first else { return nil }
        let parts = core.split(separator: ".").map { Int($0) }
        guard !parts.isEmpty, parts.allSatisfy({ $0 != nil }) else { return nil }
        self.parts = parts.compactMap { $0 }
        prerelease = pieces.count > 1 ? pieces[1].split(separator: ".").map(String.init) : []
    }

    public var isPrerelease: Bool { !prerelease.isEmpty }

    public var description: String {
        parts.map(String.init).joined(separator: ".") + (isPrerelease ? "-" + prerelease.joined(separator: ".") : "")
    }

    public static func < (lhs: ReleaseVersion, rhs: ReleaseVersion) -> Bool {
        for i in 0..<max(lhs.parts.count, rhs.parts.count) {
            let a = i < lhs.parts.count ? lhs.parts[i] : 0
            let b = i < rhs.parts.count ? rhs.parts[i] : 0
            if a != b { return a < b }
        }
        // Same numbers: the pre-release is older; two pre-releases compare label by label.
        switch (lhs.isPrerelease, rhs.isPrerelease) {
        case (false, _): return false
        case (true, false): return true
        case (true, true):
            for (a, b) in zip(lhs.prerelease, rhs.prerelease) where a != b {
                if let x = Int(a), let y = Int(b) { return x < y }
                return a < b
            }
            return lhs.prerelease.count < rhs.prerelease.count
        }
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

    /// The newest release; with `includeBetas`, the newest of the recent releases including
    /// pre-releases ("v0.2.2-beta.1"), for testing before everyone gets it.
    public func latest(includeBetas: Bool = false) async throws -> ReleaseInfo {
        let parts = repository.split(separator: "/")
        let path = includeBetas ? "releases?per_page=15" : "releases/latest"
        guard parts.count == 2, parts.allSatisfy({ !$0.isEmpty && !$0.contains(" ") }),
              let url = URL(string: "https://api.github.com/repos/\(repository)/\(path)") else {
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
        return includeBetas ? try Self.parseNewest(data) : try Self.parse(data)
    }

    /// The highest version among a release list, pre-releases included.
    static func parseNewest(_ data: Data) throws -> ReleaseInfo {
        guard let list = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { throw UpdateError.noRelease }
        let releases = list.compactMap { item -> ReleaseInfo? in
            guard let one = try? JSONSerialization.data(withJSONObject: item) else { return nil }
            return try? parse(one, allowPrerelease: true)
        }
        guard let newest = releases.max(by: { $0.version < $1.version }) else { throw UpdateError.noRelease }
        return newest
    }

    /// Whether `release` is newer than the running version.
    public static func isNewer(_ release: ReleaseInfo, than current: String) -> Bool {
        guard let running = ReleaseVersion(current) else { return false }
        return running < release.version
    }

    static func parse(_ data: Data, allowPrerelease: Bool = false) throws -> ReleaseInfo {
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
        guard release.draft != true, allowPrerelease || release.prerelease != true,
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
