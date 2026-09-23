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

    public func complete(system: String, user: String, maxTokens: Int, timeout: TimeInterval) async throws -> String {
        // Qwen 3 thinks out loud by default, which makes a two-second cleanup take twenty.
        // "/no_think" is its soft switch; LM Studio's Qwen 3 templates honour it. (Ollama goes
        // through OllamaChat instead, which has a real switch.)
        let lower = model.lowercased()
        let userContent = lower.contains("qwen3") && !lower.contains("coder") ? user + "\n/no_think" : user
        let body: [String: Any] = [
            "model": model,
            "temperature": 0,
            "max_tokens": maxTokens,
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": userContent],
            ],
        ]
        var request = URLRequest(url: baseURL.appendingPathComponent("chat/completions"))
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let apiKey, !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

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

    public init(model: String, root: URL = LocalLLM.ollama.root, client: HTTPClient = URLSessionHTTPClient()) {
        self.model = model
        self.root = root
        self.client = client
    }

    public var name: String { "Ollama \(model)" }

    public func complete(system: String, user: String, maxTokens: Int, timeout: TimeInterval) async throws -> String {
        do {
            return try await send(system: system, user: user, maxTokens: maxTokens, timeout: timeout, think: false)
        } catch let error as APIError where error.status == 400 && error.message.lowercased().contains("think") {
            // An older Ollama that does not know the switch.
            return try await send(system: system, user: user, maxTokens: maxTokens, timeout: timeout, think: nil)
        }
    }

    private func send(system: String, user: String, maxTokens: Int, timeout: TimeInterval, think: Bool?) async throws -> String {
        var body: [String: Any] = [
            "model": model,
            "stream": false,
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": user],
            ],
            "options": ["temperature": 0, "num_predict": maxTokens],
        ]
        if let think { body["think"] = think }
        var request = URLRequest(url: root.appendingPathComponent("api/chat"))
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

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
