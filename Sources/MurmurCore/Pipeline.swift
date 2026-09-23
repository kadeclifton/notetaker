import Foundation

/// A hosted API: where it lives and which `.env` key unlocks it.
public struct HostedAPI: Sendable, Equatable {
    public let name: String
    public let baseURL: URL
    public let keyName: String

    public static let groq = HostedAPI(name: "Groq", baseURL: URL(string: "https://api.groq.com/openai/v1")!, keyName: "GROQ_API_KEY")
    public static let openAI = HostedAPI(name: "OpenAI", baseURL: URL(string: "https://api.openai.com/v1")!, keyName: "OPENAI_API_KEY")
    public static let anthropic = HostedAPI(name: "Anthropic", baseURL: URL(string: "https://api.anthropic.com/v1")!, keyName: "ANTHROPIC_API_KEY")

    public func key(in env: [String: String]) -> String? {
        guard let value = env[keyName]?.trimmingCharacters(in: .whitespaces), !value.isEmpty else { return nil }
        return value
    }

    func requireKey(in env: [String: String]) throws -> String {
        guard let key = key(in: env) else { throw SetupError.missingKey(keyName) }
        return key
    }
}

extension CleanupProvider {
    public var hostedAPI: HostedAPI? {
        switch self {
        case .groq: return .groq
        case .openai: return .openAI
        case .anthropic: return .anthropic
        case .auto, .custom: return nil
        }
    }

    public var defaultModel: String {
        switch self {
        case .groq: return "llama-3.3-70b-versatile"
        case .openai: return "gpt-4.1-mini"
        case .anthropic: return "claude-haiku-4-5"
        case .custom: return "llama3.2"
        case .auto: return ""
        }
    }
}

public enum SetupError: Error, CustomStringConvertible, Equatable {
    case missingKey(String)
    case badBaseURL(String)

    public var description: String {
        switch self {
        case let .missingKey(name):
            return "\(name) is not set. Add it to ~/.config/murmur/.env, or change the provider in config.json."
        case let .badBaseURL(value):
            return "cleanup.baseURL \"\(value)\" is not a valid URL."
        }
    }
}

extension Config {
    /// Builds the transcriber the settings ask for, using API keys from `env`.
    public func makeTranscriber(env: [String: String], client: HTTPClient = URLSessionHTTPClient()) throws -> Transcriber {
        let t = transcription
        let api: HostedAPI?
        switch t.engine {
        case .auto: api = [HostedAPI.groq, .openAI].first { $0.key(in: env) != nil }
        case .groq: api = .groq
        case .openai: api = .openAI
        case .local: api = nil
        }
        if let api {
            return WhisperAPITranscriber(service: api.name, baseURL: api.baseURL, apiKey: try api.requireKey(in: env),
                                         model: api == .groq ? t.groqModel : t.openaiModel,
                                         timeout: t.timeoutSeconds, client: client)
        }
        guard let binary = WhisperCppTranscriber.locateBinary(configured: t.whisperCpp.binary, environment: env) else {
            throw TranscriptionError.whisperNotFound
        }
        return WhisperCppTranscriber(binary: binary, model: AppPaths.resolve(t.whisperCpp.model), threads: t.whisperCpp.threads)
    }

    /// Builds the cleanup LLM, or nil when cleanup is off or `auto` finds no key.
    public func makeCleaner(env: [String: String], client: HTTPClient = URLSessionHTTPClient()) throws -> TextCleaner? {
        let c = cleanup
        guard c.enabled else { return nil }
        var provider = c.provider
        if provider == .auto {
            let candidates: [CleanupProvider] = [.groq, .openai, .anthropic]
            guard let found = candidates.first(where: { $0.hostedAPI?.key(in: env) != nil }) else { return nil }
            provider = found
        }
        let model = c.model.isEmpty ? provider.defaultModel : c.model

        if provider == .custom {
            let base = c.baseURL.isEmpty ? "http://localhost:11434/v1" : c.baseURL
            guard let url = URL(string: base), url.scheme != nil else { throw SetupError.badBaseURL(base) }
            let key = env["CLEANUP_API_KEY"].flatMap { $0.isEmpty ? nil : $0 }
            return ChatCompletionsCleaner(service: url.host ?? "custom", baseURL: url, apiKey: key, model: model,
                                          timeout: c.timeoutSeconds, extraInstructions: c.extraInstructions, client: client)
        }
        guard let api = provider.hostedAPI else { return nil }
        let key = try api.requireKey(in: env)
        if api == .anthropic {
            return AnthropicCleaner(apiKey: key, model: model, timeout: c.timeoutSeconds,
                                    extraInstructions: c.extraInstructions, baseURL: api.baseURL, client: client)
        }
        return ChatCompletionsCleaner(service: api.name, baseURL: api.baseURL, apiKey: key, model: model,
                                      timeout: c.timeoutSeconds, extraInstructions: c.extraInstructions, client: client)
    }
}

public struct PipelineResult: Sendable, Equatable {
    /// What Whisper heard, after dropping non-speech markers.
    public var transcript: String
    /// What gets inserted.
    public var text: String
    /// Set when cleanup was attempted but its output was not used.
    public var cleanupProblem: String?
}

/// Audio in, text out: transcribe, then clean up. Cancelling the task stops whichever step is running.
public struct DictationPipeline: Sendable {
    public var transcriber: Transcriber
    public var cleaner: TextCleaner?
    public var language: String?
    public var prompt: String?

    public init(transcriber: Transcriber, cleaner: TextCleaner?, language: String?, prompt: String?) {
        self.transcriber = transcriber
        self.cleaner = cleaner
        self.language = language
        self.prompt = prompt
    }

    public init(config: Config, env: [String: String], client: HTTPClient = URLSessionHTTPClient()) throws {
        let language = config.transcription.language.trimmingCharacters(in: .whitespaces).lowercased()
        let vocabulary = config.transcription.vocabulary.filter { !$0.isEmpty }
        self.init(
            transcriber: try config.makeTranscriber(env: env, client: client),
            cleaner: try config.makeCleaner(env: env, client: client),
            language: language.isEmpty || language == "auto" ? nil : language,
            prompt: vocabulary.isEmpty ? nil : vocabulary.joined(separator: ", ") + "."
        )
    }

    public func run(samples: [Float], context: CleanupContext) async throws -> PipelineResult {
        let wav = Audio.wav(samples: samples)
        let heard = try await transcriber.transcribe(wav: wav, language: language, prompt: prompt)
        try Task.checkCancellation()
        let transcript = TranscriptFilter.clean(heard)
        guard !transcript.isEmpty else {
            return PipelineResult(transcript: "", text: "", cleanupProblem: nil)
        }
        guard let cleaner else {
            return PipelineResult(transcript: transcript, text: transcript, cleanupProblem: nil)
        }
        do {
            let output = try await cleaner.clean(transcript, context: context)
            try Task.checkCancellation()
            switch CleanupGuard.check(raw: transcript, cleaned: CleanupPrompt.unwrap(output, raw: transcript)) {
            case let .accept(text):
                return PipelineResult(transcript: transcript, text: text, cleanupProblem: nil)
            case let .reject(reason):
                return PipelineResult(transcript: transcript, text: transcript, cleanupProblem: "Cleanup ignored: \(reason)")
            }
        } catch {
            // Esc while the LLM is running cancels everything; any other failure (offline,
            // timeout, bad key) still inserts the raw transcript rather than losing it.
            if Task.isCancelled || error is CancellationError { throw CancellationError() }
            return PipelineResult(transcript: transcript, text: transcript, cleanupProblem: "Cleanup failed: \(error)")
        }
    }
}
