import Foundation

public enum Providers {
    public static let groqBaseURL = URL(string: "https://api.groq.com/openai/v1")!
    public static let openAIBaseURL = URL(string: "https://api.openai.com/v1")!

    public static func defaultCleanupModel(for provider: CleanupProvider) -> String {
        switch provider {
        case .groq: return "llama-3.3-70b-versatile"
        case .openai: return "gpt-4.1-mini"
        case .anthropic: return "claude-haiku-4-5"
        case .custom: return "llama3.2"
        case .auto: return ""
        }
    }

    static func key(_ name: String, in env: [String: String]) -> String? {
        guard let value = env[name]?.trimmingCharacters(in: .whitespaces), !value.isEmpty else { return nil }
        return value
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
        var engine = t.engine
        if engine == .auto {
            if Providers.key("GROQ_API_KEY", in: env) != nil {
                engine = .groq
            } else if Providers.key("OPENAI_API_KEY", in: env) != nil {
                engine = .openai
            } else {
                engine = .local
            }
        }
        switch engine {
        case .groq:
            guard let key = Providers.key("GROQ_API_KEY", in: env) else { throw SetupError.missingKey("GROQ_API_KEY") }
            return WhisperAPITranscriber(service: "Groq", baseURL: Providers.groqBaseURL, apiKey: key,
                                         model: t.groqModel, timeout: t.timeoutSeconds, client: client)
        case .openai:
            guard let key = Providers.key("OPENAI_API_KEY", in: env) else { throw SetupError.missingKey("OPENAI_API_KEY") }
            return WhisperAPITranscriber(service: "OpenAI", baseURL: Providers.openAIBaseURL, apiKey: key,
                                         model: t.openaiModel, timeout: t.timeoutSeconds, client: client)
        case .local, .auto:
            guard let binary = WhisperCppTranscriber.locateBinary(configured: t.whisperCpp.binary, environment: env) else {
                throw TranscriptionError.whisperNotFound
            }
            return WhisperCppTranscriber(binary: binary, model: AppPaths.expandTilde(t.whisperCpp.model),
                                         threads: t.whisperCpp.threads)
        }
    }

    /// Builds the cleanup LLM, or nil when cleanup is off or `auto` finds no key.
    public func makeCleaner(env: [String: String], client: HTTPClient = URLSessionHTTPClient()) throws -> TextCleaner? {
        let c = cleanup
        guard c.enabled else { return nil }
        var provider = c.provider
        if provider == .auto {
            if Providers.key("GROQ_API_KEY", in: env) != nil {
                provider = .groq
            } else if Providers.key("OPENAI_API_KEY", in: env) != nil {
                provider = .openai
            } else if Providers.key("ANTHROPIC_API_KEY", in: env) != nil {
                provider = .anthropic
            } else {
                return nil
            }
        }
        let model = c.model.isEmpty ? Providers.defaultCleanupModel(for: provider) : c.model
        switch provider {
        case .groq:
            guard let key = Providers.key("GROQ_API_KEY", in: env) else { throw SetupError.missingKey("GROQ_API_KEY") }
            return ChatCompletionsCleaner(service: "Groq", baseURL: Providers.groqBaseURL, apiKey: key, model: model,
                                          timeout: c.timeoutSeconds, extraInstructions: c.extraInstructions, client: client)
        case .openai:
            guard let key = Providers.key("OPENAI_API_KEY", in: env) else { throw SetupError.missingKey("OPENAI_API_KEY") }
            return ChatCompletionsCleaner(service: "OpenAI", baseURL: Providers.openAIBaseURL, apiKey: key, model: model,
                                          timeout: c.timeoutSeconds, extraInstructions: c.extraInstructions, client: client)
        case .anthropic:
            guard let key = Providers.key("ANTHROPIC_API_KEY", in: env) else { throw SetupError.missingKey("ANTHROPIC_API_KEY") }
            return AnthropicCleaner(apiKey: key, model: model, timeout: c.timeoutSeconds,
                                    extraInstructions: c.extraInstructions, client: client)
        case .custom:
            let base = c.baseURL.isEmpty ? "http://localhost:11434/v1" : c.baseURL
            guard let url = URL(string: base), url.scheme != nil else { throw SetupError.badBaseURL(base) }
            return ChatCompletionsCleaner(service: url.host ?? "custom", baseURL: url,
                                          apiKey: Providers.key("CLEANUP_API_KEY", in: env), model: model,
                                          timeout: c.timeoutSeconds, extraInstructions: c.extraInstructions, client: client)
        case .auto:
            return nil
        }
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
