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
        case .auto, .local, .custom: return nil
        }
    }

    public var defaultModel: String {
        switch self {
        case .groq: return "llama-3.3-70b-versatile"
        case .openai: return "gpt-4.1-mini"
        case .anthropic: return "claude-haiku-4-5"
        case .custom: return "llama3.2"
        case .auto, .local: return ""
        }
    }
}

public enum SetupError: Error, CustomStringConvertible, Equatable {
    case missingKey(String)
    case badBaseURL(String)
    case noLocalLLM

    public var description: String {
        switch self {
        case let .missingKey(name):
            return "\(name) is not set. Add it to ~/.config/murmur/.env, or change the provider in config.json."
        case let .badBaseURL(value):
            return "cleanup.baseURL \"\(value)\" is not a valid URL."
        case .noLocalLLM:
            return "No Ollama or LM Studio with a chat model is running on this Mac. Start one, or pick another provider."
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
        let model = AppPaths.resolve(t.whisperCpp.model)
        if t.whisperCpp.keepModelLoaded,
           let server = WhisperCppTranscriber.locateServer(configuredCli: t.whisperCpp.binary, environment: env) {
            let settings = WhisperServer.Settings(
                binary: server, model: model, port: t.whisperCpp.serverPort,
                threads: t.whisperCpp.threads > 0 ? t.whisperCpp.threads : WhisperCppTranscriber.defaultThreads,
                language: t.language.isEmpty ? "auto" : t.language.lowercased())
            return WhisperServerTranscriber(server: WhisperServer.shared(settings),
                                            modelName: ((model as NSString).lastPathComponent as NSString).deletingPathExtension,
                                            timeout: max(t.timeoutSeconds, 120), client: client)
        }
        guard let binary = WhisperCppTranscriber.locateBinary(configured: t.whisperCpp.binary, environment: env) else {
            throw TranscriptionError.whisperNotFound
        }
        return WhisperCppTranscriber(binary: binary, model: model, threads: t.whisperCpp.threads)
    }

    /// Builds the cleanup LLM, or nil when cleanup is off or `auto` finds nothing to use.
    public func makeCleaner(env: [String: String], local: LocalLLM? = nil,
                            client: HTTPClient = URLSessionHTTPClient()) throws -> TextCleaner? {
        let c = cleanup
        guard c.enabled,
              let chat = try makeChatModel(provider: c.provider, model: c.model, baseURL: c.baseURL,
                                           env: env, local: local, client: client) else { return nil }
        return LLMCleaner(chat: chat, timeout: c.timeoutSeconds, extraInstructions: c.extraInstructions)
    }

    /// Resolves a provider setting to a chat model. `local` is what `LocalLLM.detect` found, if anything.
    /// Returns nil only for `auto` with nothing available.
    public func makeChatModel(provider: CleanupProvider, model: String, baseURL: String = "",
                              env: [String: String], local: LocalLLM?, purpose: LocalLLM.Purpose = .cleanup,
                              client: HTTPClient = URLSessionHTTPClient()) throws -> ChatModel? {
        var provider = provider
        if provider == .auto {
            let hosted: [CleanupProvider] = [.groq, .openai, .anthropic]
            if let found = hosted.first(where: { $0.hostedAPI?.key(in: env) != nil }) {
                provider = found
            } else if local?.pickModel(preferred: model, for: purpose) != nil {
                provider = .local
            } else {
                return nil
            }
        }
        let modelName = model.isEmpty ? provider.defaultModel : model

        switch provider {
        case .local:
            // Asked for local explicitly: take the best there is, even if it is big or a code model.
            guard let local, let picked = local.pickModel(preferred: model, for: purpose)
                    ?? local.pickModel(preferred: model, for: .summary) else { throw SetupError.noLocalLLM }
            if local.isOllama {
                return OllamaChat(model: picked, client: client)
            }
            return OpenAICompatibleChat(service: local.server, baseURL: local.baseURL, apiKey: nil, model: picked, client: client)
        case .custom:
            let base = baseURL.isEmpty ? "http://localhost:11434/v1" : baseURL
            guard let url = URL(string: base), url.scheme != nil else { throw SetupError.badBaseURL(base) }
            let key = env["CLEANUP_API_KEY"].flatMap { $0.isEmpty ? nil : $0 }
            return OpenAICompatibleChat(service: url.host ?? "custom", baseURL: url, apiKey: key, model: modelName, client: client)
        case .anthropic:
            let api = HostedAPI.anthropic
            return AnthropicChat(apiKey: try api.requireKey(in: env), model: modelName, baseURL: api.baseURL, client: client)
        case .groq, .openai:
            guard let api = provider.hostedAPI else { return nil }
            return OpenAICompatibleChat(service: api.name, baseURL: api.baseURL, apiKey: try api.requireKey(in: env),
                                        model: modelName, client: client)
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
    /// How long each step took, for the menu's "Last dictation" line.
    public var transcribeSeconds: TimeInterval = 0
    public var cleanupSeconds: TimeInterval?
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

    public init(config: Config, env: [String: String], local: LocalLLM? = nil,
                client: HTTPClient = URLSessionHTTPClient()) throws {
        let language = config.transcription.language.trimmingCharacters(in: .whitespaces).lowercased()
        let vocabulary = config.transcription.vocabulary.filter { !$0.isEmpty }
        self.init(
            transcriber: try config.makeTranscriber(env: env, client: client),
            cleaner: try config.makeCleaner(env: env, local: local, client: client),
            language: language.isEmpty || language == "auto" ? nil : language,
            prompt: vocabulary.isEmpty ? nil : vocabulary.joined(separator: ", ") + "."
        )
    }

    public func run(samples: [Float], context: CleanupContext) async throws -> PipelineResult {
        let wav = Audio.wav(samples: samples)
        let transcribeStart = Date()
        let heard = try await transcriber.transcribe(wav: wav, language: language, prompt: prompt)
        let transcribeSeconds = Date().timeIntervalSince(transcribeStart)
        try Task.checkCancellation()
        let transcript = TranscriptFilter.clean(heard)
        guard !transcript.isEmpty else {
            return PipelineResult(transcript: "", text: "", cleanupProblem: nil, transcribeSeconds: transcribeSeconds)
        }
        guard let cleaner else {
            return PipelineResult(transcript: transcript, text: transcript, cleanupProblem: nil, transcribeSeconds: transcribeSeconds)
        }
        let cleanupStart = Date()
        var result: PipelineResult
        do {
            let output = try await cleaner.clean(transcript, context: context)
            try Task.checkCancellation()
            switch CleanupGuard.check(raw: transcript, cleaned: CleanupPrompt.unwrap(output, raw: transcript)) {
            case let .accept(text):
                result = PipelineResult(transcript: transcript, text: text, cleanupProblem: nil)
            case let .reject(reason):
                result = PipelineResult(transcript: transcript, text: transcript, cleanupProblem: "Cleanup ignored: \(reason)")
            }
        } catch {
            // Esc while the LLM is running cancels everything; any other failure (offline,
            // timeout, bad key) still inserts the raw transcript rather than losing it.
            if Task.isCancelled || error is CancellationError { throw CancellationError() }
            result = PipelineResult(transcript: transcript, text: transcript, cleanupProblem: "Cleanup failed: \(error)")
        }
        result.transcribeSeconds = transcribeSeconds
        result.cleanupSeconds = Date().timeIntervalSince(cleanupStart)
        return result
    }
}
