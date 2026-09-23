import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// One system prompt and one user message in, the model's text out.
/// Used for dictation cleanup and for meeting summaries.
public protocol ChatModel: Sendable {
    /// Human-readable, e.g. "Ollama qwen3:8b".
    var name: String { get }
    func complete(system: String, user: String, maxTokens: Int, timeout: TimeInterval) async throws -> String
    /// The reply in pieces as the model writes it (Compose's preview). `timeout` is the longest
    /// wait for the next piece. Models without streaming deliver the whole reply as one piece.
    func stream(system: String, user: String, maxTokens: Int, temperature: Double,
                timeout: TimeInterval) -> AsyncThrowingStream<String, Error>
}

extension ChatModel {
    public func stream(system: String, user: String, maxTokens: Int, temperature: Double,
                       timeout: TimeInterval) -> AsyncThrowingStream<String, Error> {
        ChatStream.run { yield in
            yield(try await complete(system: system, user: user, maxTokens: maxTokens, timeout: timeout))
        }
    }
}

enum ChatStream {
    /// An AsyncThrowingStream fed by `body`, cancelled when the reader stops listening.
    static func run(_ body: @escaping @Sendable (_ yield: @Sendable (String) -> Void) async throws -> Void)
        -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await body { continuation.yield($0) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// OpenAI's `/chat/completions`, which Groq, Ollama, LM Studio and llama.cpp's server also speak.
public struct OpenAICompatibleChat: ChatModel {
    public var service: String
    public var baseURL: URL
    public var apiKey: String?
    public var model: String
    public var client: HTTPClient

    public init(service: String, baseURL: URL, apiKey: String?, model: String, client: HTTPClient = URLSessionHTTPClient()) {
        self.service = service
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.model = model
        self.client = client
    }

    public var name: String { "\(service) \(model)" }

    func request(system: String, user: String, maxTokens: Int, temperature: Double,
                 timeout: TimeInterval, stream: Bool) throws -> URLRequest {
        // Qwen 3 thinks out loud by default, which makes a two-second cleanup take twenty.
        // "/no_think" is its soft switch; LM Studio's Qwen 3 templates honour it. (Ollama goes
        // through OllamaChat instead, which has a real switch.)
        let lower = model.lowercased()
        let userContent = lower.contains("qwen3") && !lower.contains("coder") ? user + "\n/no_think" : user
        var body: [String: Any] = [
            "model": model,
            "temperature": temperature,
            "max_tokens": maxTokens,
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": userContent],
            ],
        ]
        if stream { body["stream"] = true }
        var request = URLRequest(url: baseURL.appendingPathComponent("chat/completions"))
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let apiKey, !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    public func stream(system: String, user: String, maxTokens: Int, temperature: Double,
                       timeout: TimeInterval) -> AsyncThrowingStream<String, Error> {
        let client = self.client, service = self.service
        let built = Result { try request(system: system, user: user, maxTokens: maxTokens, temperature: temperature,
                                         timeout: timeout, stream: true) }
        return ChatStream.run { yield in
            // Server-sent events: "data: {json}" lines, then "data: [DONE]".
            struct Chunk: Decodable {
                struct Choice: Decodable {
                    struct Delta: Decodable { let content: String? }
                    let delta: Delta?
                }
                let choices: [Choice]
            }
            for try await line in try await HTTP.lines(try built.get(), client: client, service: service) {
                guard line.hasPrefix("data:") else { continue }
                let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                if payload == "[DONE]" { break }
                guard let chunk = try? JSONDecoder().decode(Chunk.self, from: Data(payload.utf8)) else { continue }
                if let text = chunk.choices.first?.delta?.content, !text.isEmpty { yield(text) }
            }
        }
    }

    public func complete(system: String, user: String, maxTokens: Int, timeout: TimeInterval) async throws -> String {
        let request = try request(system: system, user: user, maxTokens: maxTokens, temperature: 0,
                                  timeout: timeout, stream: false)
        let data = try await HTTP.send(request, client: client, service: service)
        struct Response: Decodable {
            struct Choice: Decodable {
                struct Message: Decodable { let content: String? }
                let message: Message
            }
            let choices: [Choice]
        }
        guard let response = try? JSONDecoder().decode(Response.self, from: data),
              let first = response.choices.first else {
            throw TranscriptionError.badResponse(String(decoding: data.prefix(200), as: UTF8.self))
        }
        return ChatText.stripThinking(first.message.content ?? "")
    }
}

/// Anthropic's Messages API.
public struct AnthropicChat: ChatModel {
    public var apiKey: String
    public var model: String
    public var baseURL: URL
    public var client: HTTPClient

    public init(apiKey: String, model: String, baseURL: URL = HostedAPI.anthropic.baseURL,
                client: HTTPClient = URLSessionHTTPClient()) {
        self.apiKey = apiKey
        self.model = model
        self.baseURL = baseURL
        self.client = client
    }

    public var name: String { "Anthropic \(model)" }

    public func complete(system: String, user: String, maxTokens: Int, timeout: TimeInterval) async throws -> String {
        let body: [String: Any] = [
            "model": model,
            "max_tokens": maxTokens,
            "temperature": 0,
            "system": system,
            "messages": [["role": "user", "content": user]],
        ]
        var request = URLRequest(url: baseURL.appendingPathComponent("messages"))
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let data = try await HTTP.send(request, client: client, service: "Anthropic")
        struct Response: Decodable {
            struct Block: Decodable {
                let type: String
                let text: String?
            }
            let content: [Block]
        }
        guard let response = try? JSONDecoder().decode(Response.self, from: data) else {
            throw TranscriptionError.badResponse(String(decoding: data.prefix(200), as: UTF8.self))
        }
        return response.content.filter { $0.type == "text" }.compactMap(\.text).joined()
    }
}

enum ChatText {
    /// Local reasoning models (Qwen 3, DeepSeek R1) put their thinking in <think>…</think> before the answer.
    static func stripThinking(_ text: String) -> String {
        guard let close = text.range(of: "</think>") else { return text }
        let open = text.range(of: "<think>")
        if let open, open.lowerBound > close.lowerBound { return text }
        return String(text[close.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Ollama's native `/api/chat`. Unlike its OpenAI-compatible endpoint it has a real switch for
/// thinking (`think: false`); the "/no_think" text trick is ignored by current Qwen 3 builds,
/// which then reason for a minute before a one-line answer.
public struct OllamaChat: ChatModel {
    public var model: String
    public var root: URL
    public var client: HTTPClient
    /// For dictation cleanup: if Ollama has not loaded the model yet (after launch, or after it
    /// unloaded it), fail at once instead of waiting 10-20 s for the load. The caller inserts the
    /// raw text, and the load that follows makes the next dictation quick.
    public var skipIfNotLoaded: Bool

    public init(model: String, root: URL = LocalLLM.ollama.root, client: HTTPClient = URLSessionHTTPClient(),
                skipIfNotLoaded: Bool = false) {
        self.model = model
        self.root = root
        self.client = client
        self.skipIfNotLoaded = skipIfNotLoaded
    }

    public var name: String { "Ollama \(model)" }

    public func complete(system: String, user: String, maxTokens: Int, timeout: TimeInterval) async throws -> String {
        if skipIfNotLoaded, await isLoaded() == false { throw ChatError.modelNotLoaded(model) }
        do {
            return try await send(system: system, user: user, maxTokens: maxTokens, timeout: timeout, think: false)
        } catch let error as APIError where error.status == 400 && error.message.lowercased().contains("think") {
            // An older Ollama that does not know the switch.
            return try await send(system: system, user: user, maxTokens: maxTokens, timeout: timeout, think: nil)
        }
    }

    /// Whether Ollama has the model in memory (`/api/ps`). Nil if Ollama did not say.
    func isLoaded() async -> Bool? {
        var request = URLRequest(url: root.appendingPathComponent("api/ps"))
        request.timeoutInterval = 1
        guard let (data, response) = try? await client.send(request), response.statusCode == 200 else { return nil }
        struct Running: Decodable {
            struct Model: Decodable {
                let name: String?
                let model: String?
            }
            let models: [Model]
        }
        guard let running = try? JSONDecoder().decode(Running.self, from: data) else { return nil }
        // "qwen3" and "qwen3:latest" are the same model.
        let wanted = model.contains(":") ? [model] : [model, model + ":latest"]
        return running.models.contains { entry in
            [entry.name, entry.model].contains { name in name.map(wanted.contains) ?? false }
        }
    }

    public func stream(system: String, user: String, maxTokens: Int, temperature: Double,
                       timeout: TimeInterval) -> AsyncThrowingStream<String, Error> {
        let chat = self
        return ChatStream.run { yield in
            do {
                try await chat.streamLines(system: system, user: user, maxTokens: maxTokens, temperature: temperature,
                                           timeout: timeout, think: false, yield: yield)
            } catch let error as APIError where error.status == 400 && error.message.lowercased().contains("think") {
                try await chat.streamLines(system: system, user: user, maxTokens: maxTokens, temperature: temperature,
                                           timeout: timeout, think: nil, yield: yield)
            }
        }
    }

    /// Streamed /api/chat: one JSON object per line.
    private func streamLines(system: String, user: String, maxTokens: Int, temperature: Double, timeout: TimeInterval,
                             think: Bool?, yield: @Sendable (String) -> Void) async throws {
        let request = try request(system: system, user: user, maxTokens: maxTokens, temperature: temperature,
                                  timeout: timeout, think: think, stream: true)
        struct Chunk: Decodable {
            struct Message: Decodable { let content: String? }
            let message: Message?
            let error: String?
            let done: Bool?
        }
        for try await line in try await HTTP.lines(request, client: client, service: "Ollama") {
            guard let chunk = try? JSONDecoder().decode(Chunk.self, from: Data(line.utf8)) else { continue }
            if let error = chunk.error { throw APIError(service: "Ollama", status: 500, message: error) }
            if let text = chunk.message?.content, !text.isEmpty { yield(text) }
            if chunk.done == true { break }
        }
    }

    private func request(system: String, user: String, maxTokens: Int, temperature: Double, timeout: TimeInterval,
                         think: Bool?, stream: Bool) throws -> URLRequest {
        var body: [String: Any] = [
            "model": model,
            "stream": stream,
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": user],
            ],
            "options": ["temperature": temperature, "num_predict": maxTokens],
        ]
        if let think { body["think"] = think }
        var request = URLRequest(url: root.appendingPathComponent("api/chat"))
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    private func send(system: String, user: String, maxTokens: Int, timeout: TimeInterval, think: Bool?) async throws -> String {
        let request = try request(system: system, user: user, maxTokens: maxTokens, temperature: 0, timeout: timeout,
                                  think: think, stream: false)
        let data = try await HTTP.send(request, client: client, service: "Ollama")
        struct Response: Decodable {
            struct Message: Decodable { let content: String? }
            let message: Message
        }
        guard let response = try? JSONDecoder().decode(Response.self, from: data) else {
            throw TranscriptionError.badResponse(String(decoding: data.prefix(200), as: UTF8.self))
        }
        return ChatText.stripThinking(response.message.content ?? "")
    }
}

public enum ChatError: Error, CustomStringConvertible, Equatable {
    case modelNotLoaded(String)

    public var description: String {
        switch self {
        case let .modelNotLoaded(model):
            return "\(model) was still loading, so this dictation was inserted without cleanup. The next one will be cleaned up."
        }
    }
}
