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
    }

    /// Chat-model families that follow instructions well, best first.
    static let preferredFamilies = ["qwen3", "qwen2.5", "llama3.2", "llama3.1", "gemma3", "gemma2", "mistral", "phi4", "phi3", "llama"]
    /// Models that cannot chat: embeddings, speech, vision encoders.
    static let nonChatMarkers = ["embed", "bge", "minilm", "whisper", "clip", "rerank"]
    /// Code models chat, but rewrite prose poorly; used only when nothing else is there.
    static let codeMarkers = ["coder", "code", "starcoder", "codestral"]
    /// Above this, a model is too slow to run on every dictation (about 8B parameters at 4-bit).
    static let cleanupMaxBytes: Int64 = 6_000_000_000
    static let cleanupMaxBillions = 9.0

    /// The configured model if one is set, else the best model on offer for the purpose.
    /// For cleanup only small general chat models qualify; nil means "don't use a local model".
    public func pickModel(preferred: String = "", for purpose: Purpose = .cleanup) -> String? {
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
        }
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
