import XCTest
@testable import MurmurCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

final class LocalLLMTests: XCTestCase {
    let ollama = LocalLLM(server: "Ollama", baseURL: URL(string: "http://127.0.0.1:11434/v1")!,
                          models: ["nomic-embed-text:latest", "deepseek-r1:14b", "llama3.2:3b", "qwen3:8b"])

    func testPicksPreferredChatModel() {
        XCTAssertEqual(ollama.pickModel(), "qwen3:8b")
        XCTAssertEqual(ollama.pickModel(preferred: "llama3.2:3b"), "llama3.2:3b")
        let odd = LocalLLM(server: "LM Studio", baseURL: ollama.baseURL, models: ["text-embedding-bge", "some-custom-model"])
        XCTAssertEqual(odd.pickModel(), "some-custom-model")
        let embeddingsOnly = LocalLLM(server: "Ollama", baseURL: ollama.baseURL, models: ["nomic-embed-text"])
        XCTAssertNil(embeddingsOnly.pickModel())
    }

    func testDetectsOllama() async {
        let client = FakeHTTPClient { request in
            if request.url?.absoluteString == "http://127.0.0.1:11434/api/tags" {
                return (200, #"{"models":[{"name":"llama3.2:3b","size":2019393189}]}"#)
            }
            throw URLError(.cannotConnectToHost)
        }
        let found = await LocalLLM.detect(client: client)
        XCTAssertEqual(found, LocalLLM(server: "Ollama", baseURL: URL(string: "http://127.0.0.1:11434/v1")!,
                                       models: ["llama3.2:3b"], sizes: ["llama3.2:3b": 2_019_393_189]))
    }

    func testFallsBackToLMStudio() async {
        let client = FakeHTTPClient { request in
            if request.url?.absoluteString == "http://127.0.0.1:1234/v1/models" {
                return (200, #"{"data":[{"id":"qwen2.5-7b-instruct","object":"model"}]}"#)
            }
            throw URLError(.cannotConnectToHost)
        }
        let found = await LocalLLM.detect(client: client)
        XCTAssertEqual(found?.server, "LM Studio")
        XCTAssertEqual(found?.models, ["qwen2.5-7b-instruct"])
    }

    func testNothingRunning() async {
        let client = FakeHTTPClient { _ in throw URLError(.cannotConnectToHost) }
        let found = await LocalLLM.detect(client: client)
        XCTAssertNil(found)
    }

    func testAutoUsesLocalWhenNoKeys() throws {
        let config = Config()
        XCTAssertEqual(try config.makeCleaner(env: [:], local: ollama)?.name, "Ollama qwen3:8b")
        XCTAssertEqual(try config.makeCleaner(env: ["GROQ_API_KEY": "g"], local: ollama)?.name, "Groq llama-3.3-70b-versatile",
                       "a key still wins under auto")
        XCTAssertNil(try config.makeCleaner(env: [:], local: nil))
    }

    func testForcedLocal() throws {
        var config = Config()
        config.cleanup.provider = .local
        XCTAssertEqual(try config.makeCleaner(env: ["GROQ_API_KEY": "g"], local: ollama)?.name, "Ollama qwen3:8b")
        config.cleanup.model = "llama3.2:3b"
        XCTAssertEqual(try config.makeCleaner(env: [:], local: ollama)?.name, "Ollama llama3.2:3b")
        XCTAssertThrowsError(try config.makeCleaner(env: [:], local: nil)) {
            XCTAssertEqual($0 as? SetupError, .noLocalLLM)
        }
    }

    func testQwen3AnswersDirectlyAndThinkingIsStripped() async throws {
        let client = FakeHTTPClient { _ in (200, #"{"choices":[{"message":{"content":"<think>\nhmm\n</think>\n\nHello."}}]}"#) }
        let chat = OpenAICompatibleChat(service: "Ollama", baseURL: ollama.baseURL, apiKey: nil, model: "qwen3:8b", client: client)
        let reply = try await chat.complete(system: "s", user: "u", maxTokens: 10, timeout: 5)
        XCTAssertEqual(reply, "Hello.")
        let request = try XCTUnwrap(client.requests.first)
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        let messages = try XCTUnwrap(jsonBody(request)["messages"] as? [[String: String]])
        XCTAssertEqual(messages[1]["content"], "u\n/no_think")
    }
}

final class LocalModelChoiceTests: XCTestCase {
    let url = URL(string: "http://127.0.0.1:11434/v1")!

    func testBigCodeModelIsNotUsedForCleanup() throws {
        let only = LocalLLM(server: "Ollama", baseURL: url, models: ["qwen3-coder:30b"], sizes: ["qwen3-coder:30b": 18_556_700_000])
        XCTAssertNil(only.pickModel(for: .cleanup), "too big and a code model: dictation would crawl")
        XCTAssertEqual(only.pickModel(for: .summary), "qwen3-coder:30b", "fine for a once-per-meeting summary")
        XCTAssertNil(try Config().makeCleaner(env: [:], local: only), "auto skips cleanup rather than slowing dictation")
        var forced = Config()
        forced.cleanup.provider = .local
        XCTAssertEqual(try forced.makeCleaner(env: [:], local: only)?.name, "Ollama qwen3-coder:30b",
                       "asking for local explicitly still uses what is there")
    }

    func testCleanupPicksTheSmallGeneralModel() {
        let mix = LocalLLM(server: "Ollama", baseURL: url,
                           models: ["qwen3-coder:30b", "qwen3:14b", "qwen3:4b", "llama3.2:3b"],
                           sizes: ["qwen3-coder:30b": 18_000_000_000, "qwen3:14b": 9_300_000_000,
                                   "qwen3:4b": 2_600_000_000, "llama3.2:3b": 2_000_000_000])
        XCTAssertEqual(mix.pickModel(for: .cleanup), "qwen3:4b")
        XCTAssertEqual(mix.pickModel(for: .summary), "qwen3:14b")
    }

    func testSizeFromTheNameWhenTheServerDoesNotSay() {
        let lmStudio = LocalLLM(server: "LM Studio", baseURL: url, models: ["qwen2.5-32b-instruct", "qwen2.5-7b-instruct"])
        XCTAssertEqual(lmStudio.pickModel(for: .cleanup), "qwen2.5-7b-instruct")
        XCTAssertEqual(lmStudio.pickModel(for: .summary), "qwen2.5-32b-instruct")
        XCTAssertEqual(LocalLLM.parameterBillions(in: "llama3.2:3b"), 3)
        XCTAssertEqual(LocalLLM.parameterBillions(in: "qwen2.5-7b-instruct"), 7)
        XCTAssertEqual(LocalLLM.parameterBillions(in: "qwen3-coder:30b"), 30)
        XCTAssertNil(LocalLLM.parameterBillions(in: "phi3"))
    }

    func testCoderModelGetsNoThinkingSwitch() async throws {
        let client = FakeHTTPClient { _ in (200, #"{"choices":[{"message":{"content":"ok"}}]}"#) }
        let chat = OpenAICompatibleChat(service: "Ollama", baseURL: url, apiKey: nil, model: "qwen3-coder:30b", client: client)
        _ = try await chat.complete(system: "s", user: "u", maxTokens: 10, timeout: 5)
        let messages = try XCTUnwrap(jsonBody(try XCTUnwrap(client.requests.first))["messages"] as? [[String: String]])
        XCTAssertEqual(messages[1]["content"], "u")
    }

    func testPipelineReportsTimings() async throws {
        let pipeline = DictationPipeline(transcriber: FakeTranscriber(text: "hello there"),
                                         cleaner: FakeCleaner { _ in "Hello there." }, language: nil, prompt: nil)
        let result = try await pipeline.run(samples: [Float](repeating: 0.1, count: 16_000), context: CleanupContext())
        XCTAssertGreaterThanOrEqual(result.transcribeSeconds, 0)
        XCTAssertNotNil(result.cleanupSeconds)
        let raw = DictationPipeline(transcriber: FakeTranscriber(text: "hi"), cleaner: nil, language: nil, prompt: nil)
        let rawResult = try await raw.run(samples: [0.1], context: CleanupContext())
        XCTAssertNil(rawResult.cleanupSeconds)
    }
}

final class KeepAliveTests: XCTestCase {
    func testRequestBody() throws {
        let request = LocalLLM.keepAliveRequest(model: "qwen3:4b", keepAlive: .oneHour)
        XCTAssertEqual(request.url?.absoluteString, "http://127.0.0.1:11434/api/generate")
        XCTAssertEqual(request.httpMethod, "POST")
        let body = jsonBody(request)
        XCTAssertEqual(body["model"] as? String, "qwen3:4b")
        XCTAssertEqual(body["keep_alive"] as? String, "1h")
        XCTAssertNil(body["prompt"], "no prompt: just load and set the timer")
        XCTAssertEqual(jsonBody(LocalLLM.keepAliveRequest(model: "m", keepAlive: .always))["keep_alive"] as? Int, -1)
    }

    func testDefaultsAndTitles() {
        XCTAssertEqual(KeepAlive.default, .thirtyMinutes)
        XCTAssertEqual(KeepAlive(rawValue: "4h"), .fourHours)
        XCTAssertTrue(KeepAlive.allCases.allSatisfy { !$0.title.isEmpty })
    }
}

final class OllamaChatTests: XCTestCase {
    func testSwitchesThinkingOffWithTheRealFlag() async throws {
        let client = FakeHTTPClient { _ in (200, #"{"model":"qwen3:4b","message":{"role":"assistant","content":"So I was thinking we could meet tomorrow at 3."},"done":true}"#) }
        let chat = OllamaChat(model: "qwen3:4b", client: client)
        let reply = try await chat.complete(system: "clean", user: "so um", maxTokens: 64, timeout: 5)
        XCTAssertEqual(reply, "So I was thinking we could meet tomorrow at 3.")
        let request = try XCTUnwrap(client.requests.first)
        XCTAssertEqual(request.url?.absoluteString, "http://127.0.0.1:11434/api/chat")
        let body = jsonBody(request)
        XCTAssertEqual(body["think"] as? Bool, false)
        XCTAssertEqual(body["stream"] as? Bool, false)
        XCTAssertEqual((body["options"] as? [String: Any])?["num_predict"] as? Int, 64)
        let messages = try XCTUnwrap(body["messages"] as? [[String: String]])
        XCTAssertEqual(messages.map { $0["content"] }, ["clean", "so um"], "no /no_think text added")
    }

    func testOlderOllamaWithoutTheFlag() async throws {
        let calls = Counter()
        let client = FakeHTTPClient { _ in
            if calls.next() == 1 { return (400, #"{"error":"invalid option: think"}"#) }
            return (200, #"{"message":{"content":"<think>x</think>Hi."}}"#)
        }
        let reply = try await OllamaChat(model: "qwen3:4b", client: client).complete(system: "s", user: "u", maxTokens: 8, timeout: 5)
        XCTAssertEqual(reply, "Hi.")
        XCTAssertEqual(client.requests.count, 2)
        XCTAssertNil(jsonBody(client.requests[1])["think"])
    }

    func testLocalOllamaUsesTheNativeAPI() throws {
        let local = LocalLLM(server: "Ollama", baseURL: URL(string: "http://127.0.0.1:11434/v1")!, models: ["qwen3:4b"])
        let cleaner = try XCTUnwrap(try Config().makeCleaner(env: [:], local: local) as? LLMCleaner)
        XCTAssertTrue(cleaner.chat is OllamaChat)
        let lmStudio = LocalLLM(server: "LM Studio", baseURL: URL(string: "http://127.0.0.1:1234/v1")!, models: ["qwen2.5-7b-instruct"])
        let other = try XCTUnwrap(try Config().makeCleaner(env: [:], local: lmStudio) as? LLMCleaner)
        XCTAssertTrue(other.chat is OpenAICompatibleChat)
    }
}

final class OllamaLoadedTests: XCTestCase {
    func chat(_ ps: @escaping @Sendable () -> (Int, String)) -> (OllamaChat, FakeHTTPClient) {
        let client = FakeHTTPClient { request in
            if request.url?.path == "/api/ps" { return ps() }
            return (200, #"{"message":{"content":"Hello."}}"#)
        }
        return (OllamaChat(model: "qwen3:4b", client: client, skipIfNotLoaded: true), client)
    }

    func testSkipsWhileTheModelIsLoading() async {
        let (ollama, client) = chat { (200, #"{"models":[{"name":"qwen3-coder:30b","model":"qwen3-coder:30b"}]}"#) }
        do {
            _ = try await ollama.complete(system: "s", user: "u", maxTokens: 8, timeout: 10)
            XCTFail("expected a skip")
        } catch {
            XCTAssertEqual(error as? ChatError, .modelNotLoaded("qwen3:4b"))
        }
        XCTAssertEqual(client.requests.count, 1, "no chat request that would wait for the load")
    }

    func testRunsWhenLoaded() async throws {
        let (ollama, _) = chat { (200, #"{"models":[{"name":"qwen3:4b","model":"qwen3:4b"}]}"#) }
        let reply = try await ollama.complete(system: "s", user: "u", maxTokens: 8, timeout: 10)
        XCTAssertEqual(reply, "Hello.")
    }

    func testRunsWhenOllamaCannotSay() async throws {
        let (ollama, _) = chat { (404, "not found") }
        let reply = try await ollama.complete(system: "s", user: "u", maxTokens: 8, timeout: 10)
        XCTAssertEqual(reply, "Hello.")
    }

    func testLatestTagMatches() async {
        let client = FakeHTTPClient { _ in (200, #"{"models":[{"name":"llama3.2:latest","model":"llama3.2:latest"}]}"#) }
        let loaded = await OllamaChat(model: "llama3.2", client: client).isLoaded()
        XCTAssertEqual(loaded, true)
    }

    func testOnlyCleanupSkips() throws {
        let local = LocalLLM(server: "Ollama", baseURL: URL(string: "http://127.0.0.1:11434/v1")!, models: ["qwen3:4b"])
        let cleanup = try XCTUnwrap(try Config().makeChatModel(provider: .local, model: "", env: [:], local: local, purpose: .cleanup) as? OllamaChat)
        let summary = try XCTUnwrap(try Config().makeChatModel(provider: .local, model: "", env: [:], local: local, purpose: .summary) as? OllamaChat)
        XCTAssertTrue(cleanup.skipIfNotLoaded)
        XCTAssertFalse(summary.skipIfNotLoaded, "a meeting summary can wait for the load")
    }

    func testReadableFailures() {
        XCTAssertTrue(DictationPipeline.describeCleanupFailure(URLError(.timedOut)).hasPrefix("Cleanup took longer"))
        XCTAssertTrue(DictationPipeline.describeCleanupFailure(ChatError.modelNotLoaded("qwen3:4b")).hasPrefix("qwen3:4b was still loading"))
        XCTAssertFalse(DictationPipeline.describeCleanupFailure(URLError(.timedOut)).contains("NSURLErrorDomain"))
    }
}
