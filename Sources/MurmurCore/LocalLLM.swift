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

    public init(server: String, baseURL: URL, models: [String]) {
        self.server = server
        self.baseURL = baseURL
        self.models = models
    }

    /// Chat-model families that follow instructions well, best first.
    static let preferredFamilies = ["qwen3", "qwen2.5", "llama3.2", "llama3.1", "gemma3", "gemma2", "mistral", "phi4", "phi3", "llama"]
    /// Models that cannot chat: embeddings, speech, vision encoders.
    static let nonChatMarkers = ["embed", "bge", "minilm", "whisper", "clip", "rerank"]

    /// The configured model if the server has it (or it is set at all), else the best chat model on offer.
    public func pickModel(preferred: String = "") -> String? {
        if !preferred.isEmpty { return preferred }
        let chat = models.filter { name in
            let lower = name.lowercased()
            return !Self.nonChatMarkers.contains { lower.contains($0) }
        }
        for family in Self.preferredFamilies {
            if let match = chat.first(where: { $0.lowercased().contains(family) }) { return match }
        }
        return chat.first
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
            struct Model: Decodable { let name: String }
            let models: [Model]
        }
        guard let tags = try? JSONDecoder().decode(Tags.self, from: data), !tags.models.isEmpty else { return nil }
        return LocalLLM(server: ollama.name, baseURL: ollama.root.appendingPathComponent("v1"), models: tags.models.map(\.name))
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
