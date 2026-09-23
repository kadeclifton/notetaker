import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// A chat model server already running on this Mac: Ollama or LM Studio.
public struct LocalLLM: Sendable, Equatable {
    public var server: String
    /// OpenAI-compatible base URL, e.g. http://127.0.0.1:11434/v1.
    public var baseURL: URL
    public var models: [String]
    /// Download size in bytes, where the server reports it (Ollama does).
    public var sizes: [String: Int64]

    public init(server: String, baseURL: URL, models: [String], sizes: [String: Int64] = [:]) {
        self.server = server
        self.baseURL = baseURL
        self.models = models
        self.sizes = sizes
    }

    public enum Purpose: Sendable {
        /// Dictation cleanup runs on every dictation, so it needs a small, fast model.
        case cleanup
        /// Meeting summaries run once per meeting; a bigger model is worth the wait.
        case summary
        /// Compose rewrites long rambles on request: the most capable model that fits in memory.
        case compose
    }

    /// Chat-model families that follow instructions well, best first.
    static let preferredFamilies = ["qwen3", "qwen2.5", "llama3.2", "llama3.1", "gemma3", "gemma2", "mistral", "phi4", "phi3", "llama"]
    /// Models that cannot chat: embeddings, speech, vision encoders.
    public static let nonChatMarkers = ["embed", "bge", "minilm", "whisper", "clip", "rerank"]
    /// Code models chat, but rewrite prose poorly; used only when nothing else is there.
    static let codeMarkers = ["coder", "code", "starcoder", "codestral"]
    /// Above this, a model is too slow to run on every dictation (about 8B parameters at 4-bit).
    static let cleanupMaxBytes: Int64 = 6_000_000_000
    static let cleanupMaxBillions = 9.0

    /// The configured model if one is set, else the best model on offer for the purpose.
    /// For cleanup only small general chat models qualify; nil means "don't use a local model".
    public func pickModel(preferred: String = "", for purpose: Purpose = .cleanup,
                          memoryBytes: UInt64 = ProcessInfo.processInfo.physicalMemory) -> String? {
        if !preferred.isEmpty { return preferred }
        let chat = models.filter { name in
            let lower = name.lowercased()
            return !Self.nonChatMarkers.contains { lower.contains($0) }
        }
        let general = chat.filter { !isCode($0) }
        switch purpose {
        case .cleanup:
            let small = general.filter(isSmall)
            // Smallest first within the preferred order, so dictation stays quick.
            return best(in: small, smallestFirst: true)
        case .summary:
            return best(in: general, smallestFirst: false) ?? best(in: chat, smallestFirst: false)
        case .compose:
            let fits = general.filter { fitsInMemory($0, memoryBytes: memoryBytes) }
            return best(in: fits, smallestFirst: false)
                ?? general.min { size(of: $0) < size(of: $1) }
                ?? best(in: chat, smallestFirst: false)
        }
    }

    /// Room for macOS, the apps you have open, and the speech model: a model may use up to 60% of memory.
    static let composeMemoryShare = 0.6

    func fitsInMemory(_ name: String, memoryBytes: UInt64) -> Bool {
        let bytes = sizes[name].map(Double.init) ?? Self.parameterBillions(in: name).map { $0 * 600_000_000 }
        guard let bytes else { return true }
        return bytes <= Double(memoryBytes) * Self.composeMemoryShare
    }

    /// The Ollama model worth pulling for Compose on a Mac with this much memory.
    public static func suggestedComposeModel(memoryBytes: UInt64 = ProcessInfo.processInfo.physicalMemory) -> String {
        let gigabytes = Double(memoryBytes) / 1_073_741_824
        if gigabytes >= 31 { return "qwen3:30b" }
        if gigabytes >= 23 { return "qwen3:14b" }
        if gigabytes >= 15 { return "qwen3:8b" }
        return "qwen3:4b"
    }

    /// "18.6 GB", or nil if the server did not say.
    public func sizeDescription(of name: String) -> String? {
        guard let bytes = sizes[name] else { return nil }
        return String(format: "%.1f GB", Double(bytes) / 1_000_000_000)
    }

    private func best(in names: [String], smallestFirst: Bool) -> String? {
        for family in Self.preferredFamilies {
            let matches = names.filter { $0.lowercased().contains(family) }
            guard !matches.isEmpty else { continue }
            let sorted = matches.sorted { size(of: $0) < size(of: $1) }
            return smallestFirst ? sorted.first : sorted.last
        }
        return smallestFirst ? names.min { size(of: $0) < size(of: $1) } : names.first
    }

    private func isCode(_ name: String) -> Bool {
        let lower = name.lowercased()
        return Self.codeMarkers.contains { lower.contains($0) }
    }

    private func isSmall(_ name: String) -> Bool {
        if let bytes = sizes[name] { return bytes <= Self.cleanupMaxBytes }
        if let billions = Self.parameterBillions(in: name) { return billions <= Self.cleanupMaxBillions }
        return true // no size information at all: let it through
    }

    /// Size for sorting: bytes when known, else parameters from the name, else unknown last.
    private func size(of name: String) -> Double {
        if let bytes = sizes[name] { return Double(bytes) }
        if let billions = Self.parameterBillions(in: name) { return billions * 600_000_000 }
        return .greatestFiniteMagnitude
    }

    /// "qwen2.5-7b-instruct" → 7, "llama3.2:3b" → 3, "qwen3-coder:30b" → 30, "phi3" → nil.
    static func parameterBillions(in name: String) -> Double? {
        let lower = name.lowercased()
        guard let range = lower.range(of: #"(?<![a-z0-9.])(\d+(\.\d+)?)b(?![a-z])"#, options: .regularExpression) else { return nil }
        return Double(lower[range].dropLast())
    }

    public static let ollama = (name: "Ollama", root: URL(string: "http://127.0.0.1:11434")!)
    public static let lmStudio = (name: "LM Studio", root: URL(string: "http://127.0.0.1:1234")!)

    /// Looks for Ollama, then LM Studio. Quick: each probe gives up after a second.
    public static func detect(client: HTTPClient = URLSessionHTTPClient()) async -> LocalLLM? {
        if let found = await probeOllama(client: client) { return found }
        return await probeLMStudio(client: client)
    }

    static func probeOllama(client: HTTPClient) async -> LocalLLM? {
        var request = URLRequest(url: ollama.root.appendingPathComponent("api/tags"))
        request.timeoutInterval = 1
        guard let (data, response) = try? await client.send(request), response.statusCode == 200 else { return nil }
        struct Tags: Decodable {
            struct Model: Decodable {
                let name: String
                let size: Int64?
            }
            let models: [Model]
        }
        guard let tags = try? JSONDecoder().decode(Tags.self, from: data), !tags.models.isEmpty else { return nil }
        var sizes: [String: Int64] = [:]
        for model in tags.models { sizes[model.name] = model.size }
        return LocalLLM(server: ollama.name, baseURL: ollama.root.appendingPathComponent("v1"),
                        models: tags.models.map(\.name), sizes: sizes)
    }

    static func probeLMStudio(client: HTTPClient) async -> LocalLLM? {
        var request = URLRequest(url: lmStudio.root.appendingPathComponent("v1/models"))
        request.timeoutInterval = 1
        guard let (data, response) = try? await client.send(request), response.statusCode == 200 else { return nil }
        struct Models: Decodable {
            struct Model: Decodable { let id: String }
            let data: [Model]
        }
        guard let list = try? JSONDecoder().decode(Models.self, from: data), !list.data.isEmpty else { return nil }
        return LocalLLM(server: lmStudio.name, baseURL: lmStudio.root.appendingPathComponent("v1"), models: list.data.map(\.id))
    }
}

// MARK: - Keeping the cleanup model loaded

/// How long Ollama keeps a model in memory after its last request. Ollama's own default is five
/// minutes; after that the next dictation waits a few seconds while the model loads again.
public enum KeepAlive: String, CaseIterable, Sendable {
    case fiveMinutes = "5m"
    case thirtyMinutes = "30m"
    case oneHour = "1h"
    case fourHours = "4h"
    case always = "forever"

    public static let `default` = KeepAlive.thirtyMinutes

    public var title: String {
        switch self {
        case .fiveMinutes: return "5 minutes (Ollama's default)"
        case .thirtyMinutes: return "30 minutes"
        case .oneHour: return "1 hour"
        case .fourHours: return "4 hours"
        case .always: return "Always, while Ollama runs"
        }
    }

    /// Ollama takes a duration string, or a negative number for "never unload".
    var ollamaValue: Any { self == .always ? -1 : rawValue }
}

extension LocalLLM {
    public var isOllama: Bool { server == Self.ollama.name }

    /// An empty /api/generate request loads the model (if needed) and sets how long it stays loaded.
    /// Ollama's OpenAI-compatible endpoint has no keep-alive setting, so Murmur sends this after each
    /// cleanup to restore the chosen time, and once at launch to load the model before the first dictation.
    public static func keepAliveRequest(model: String, keepAlive: KeepAlive) -> URLRequest {
        var request = URLRequest(url: ollama.root.appendingPathComponent("api/generate"))
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["model": model, "keep_alive": keepAlive.ollamaValue])
        return request
    }

    public static func keepLoaded(model: String, for keepAlive: KeepAlive,
                                  client: HTTPClient = URLSessionHTTPClient()) async {
        _ = try? await client.send(keepAliveRequest(model: model, keepAlive: keepAlive))
    }
}
