import Foundation

/// Where Murmur is willing to send things.
public enum NetworkSafety {
    /// https anywhere; plain http only to this Mac or the local network (Ollama, LM Studio, a
    /// llama.cpp box on the LAN), never across the internet where text and keys could be read.
    public static func isAllowed(_ url: URL) -> Bool {
        switch url.scheme?.lowercased() {
        case "https": return true
        case "http": return url.host.map(isLocal) ?? false
        default: return false
        }
    }

    public static func isLocal(_ host: String) -> Bool {
        let host = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if host == "localhost" || host == "::1" || host.hasSuffix(".local") || host.hasPrefix("fe80:") { return true }
        let parts = host.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 4, parts.allSatisfy({ (0...255).contains($0) }) else { return false }
        switch (parts[0], parts[1]) {
        case (127, _), (10, _), (192, 168), (169, 254): return true
        case (172, 16...31): return true
        default: return false
        }
    }

    /// Release downloads come from github.com over https (GitHub redirects to its own storage).
    public static func isGitHubDownload(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https", let host = url.host?.lowercased() else { return false }
        return host == "github.com" || host.hasSuffix(".githubusercontent.com")
    }
}
