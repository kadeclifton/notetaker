import XCTest
@testable import MurmurCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Records requests and answers them from a closure.
final class FakeHTTPClient: HTTPClient, @unchecked Sendable {
    private let lock = NSLock()
    private var _requests: [URLRequest] = []
    let respond: @Sendable (URLRequest) async throws -> (Int, String)

    init(respond: @escaping @Sendable (URLRequest) async throws -> (Int, String)) {
        self.respond = respond
    }

    var requests: [URLRequest] {
        lock.withLock { _requests }
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        lock.withLock { _requests.append(request) }
        let (status, body) = try await respond(request)
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        return (Data(body.utf8), response)
    }
}

struct FakeTranscriber: Transcriber {
    var text: String
    var name: String { "fake" }
    func transcribe(wav: Data, language: String?, prompt: String?) async throws -> String { text }
}

struct FakeCleaner: TextCleaner {
    var result: @Sendable (String) async throws -> String
    var name: String { "fake" }
    func clean(_ transcript: String, context: CleanupContext) async throws -> String { try await result(transcript) }
}

func jsonBody(_ request: URLRequest) -> [String: Any] {
    (try? JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any]) ?? [:]
}

final class ProviderSelectionTests: XCTestCase {
    func testAutoPrefersGroqThenOpenAI() throws {
        let config = Config()
        let groq = try config.makeTranscriber(env: ["GROQ_API_KEY": "g", "OPENAI_API_KEY": "o"])
        XCTAssertEqual(groq.name, "Groq whisper-large-v3-turbo")
        let openai = try config.makeTranscriber(env: ["OPENAI_API_KEY": "o"])
        XCTAssertEqual(openai.name, "OpenAI whisper-1")
    }

    func testAutoFallsBackToLocal() {
        var config = Config()
        config.transcription.whisperCpp.binary = "/nonexistent/whisper-cli"
        XCTAssertThrowsError(try config.makeTranscriber(env: [:])) {
            XCTAssertEqual($0 as? TranscriptionError, .whisperNotFound)
        }
        config.transcription.whisperCpp.binary = "/bin/sh"
        config.transcription.whisperCpp.model = "/models/ggml-medium.en.bin"
        XCTAssertEqual(try config.makeTranscriber(env: [:]).name, "whisper.cpp (ggml-medium.en)")
    }

    func testRelativeModelPathIsInsideTheSettingsDirectory() throws {
        var config = Config()
        config.transcription.engine = .local
        config.transcription.whisperCpp.binary = "/bin/sh"
        let transcriber = try XCTUnwrap(try config.makeTranscriber(env: [:]) as? WhisperCppTranscriber)
        XCTAssertEqual(transcriber.model, AppPaths.directory.appendingPathComponent("models/ggml-small.en.bin").path)
    }

    func testLocalIgnoresKeys() throws {
        var config = Config()
        config.transcription.engine = .local
        config.transcription.whisperCpp.binary = "/bin/sh"
        XCTAssertTrue(try config.makeTranscriber(env: ["GROQ_API_KEY": "g"]) is WhisperCppTranscriber)
    }

    func testForcedProviderNeedsKey() {
        var config = Config()
        config.transcription.engine = .openai
        XCTAssertThrowsError(try config.makeTranscriber(env: ["OPENAI_API_KEY": "  "])) {
            XCTAssertEqual($0 as? SetupError, .missingKey("OPENAI_API_KEY"))
        }
    }

    func testCleanerSelection() throws {
        var config = Config()
        XCTAssertNil(try config.makeCleaner(env: [:]), "no key: cleanup skipped, works offline")
        XCTAssertEqual(try config.makeCleaner(env: ["ANTHROPIC_API_KEY": "a"])?.name, "Anthropic claude-haiku-4-5")
        XCTAssertEqual(try config.makeCleaner(env: ["OPENAI_API_KEY": "o", "ANTHROPIC_API_KEY": "a"])?.name, "OpenAI gpt-4.1-mini")
        config.cleanup.provider = .custom
        config.cleanup.model = "qwen3"
        XCTAssertEqual(try config.makeCleaner(env: [:])?.name, "localhost qwen3")
        config.cleanup.enabled = false
        XCTAssertNil(try config.makeCleaner(env: ["GROQ_API_KEY": "g"]))
    }
}

final class APIClientTests: XCTestCase {
    func testWhisperAPIRequest() async throws {
        let client = FakeHTTPClient { _ in (200, #"{"text":" hello there "}"#) }
        let transcriber = WhisperAPITranscriber(service: "Groq", baseURL: HostedAPI.groq.baseURL, apiKey: "gsk",
                                                model: "whisper-large-v3-turbo", client: client)
        let text = try await transcriber.transcribe(wav: Data([1, 2, 3]), language: "en", prompt: "Kubernetes.")
        XCTAssertEqual(text, " hello there ")
        let request = try XCTUnwrap(client.requests.first)
        XCTAssertEqual(request.url?.absoluteString, "https://api.groq.com/openai/v1/audio/transcriptions")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer gsk")
        XCTAssertTrue(request.value(forHTTPHeaderField: "Content-Type")?.hasPrefix("multipart/form-data; boundary=") ?? false)
        let body = String(decoding: request.httpBody ?? Data(), as: UTF8.self)
        XCTAssertTrue(body.contains("name=\"model\"\r\n\r\nwhisper-large-v3-turbo\r\n"))
        XCTAssertTrue(body.contains("name=\"language\"\r\n\r\nen\r\n"))
        XCTAssertTrue(body.contains("name=\"prompt\"\r\n\r\nKubernetes.\r\n"))
        XCTAssertTrue(body.contains("filename=\"audio.wav\""))
    }

    func testAPIErrorsCarryTheMessage() async {
        let client = FakeHTTPClient { _ in (401, #"{"error":{"message":"Invalid API Key"}}"#) }
        let transcriber = WhisperAPITranscriber(service: "Groq", baseURL: HostedAPI.groq.baseURL, apiKey: "bad",
                                                model: "m", client: client)
        do {
            _ = try await transcriber.transcribe(wav: Data(), language: nil, prompt: nil)
            XCTFail("expected an error")
        } catch let error as APIError {
            XCTAssertEqual(error.status, 401)
            XCTAssertEqual(error.description, "Groq returned HTTP 401 (check the API key in .env): Invalid API Key")
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    func testChatCompletionsRequest() async throws {
        let client = FakeHTTPClient { _ in (200, #"{"choices":[{"message":{"role":"assistant","content":"Hello, world."}}]}"#) }
        let cleaner = LLMCleaner(chat: OpenAICompatibleChat(service: "OpenAI", baseURL: HostedAPI.openAI.baseURL, apiKey: "sk",
                                                             model: "gpt-4.1-mini", client: client),
                                 extraInstructions: "Use British spelling.")
        let output = try await cleaner.clean("um hello world", context: CleanupContext(appName: "Slack"))
        XCTAssertEqual(output, "Hello, world.")
        let request = try XCTUnwrap(client.requests.first)
        XCTAssertEqual(request.url?.absoluteString, "https://api.openai.com/v1/chat/completions")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer sk")
        let body = jsonBody(request)
        XCTAssertEqual(body["model"] as? String, "gpt-4.1-mini")
        let messages = try XCTUnwrap(body["messages"] as? [[String: String]])
        XCTAssertEqual(messages.map { $0["role"] }, ["system", "user"])
        XCTAssertTrue(messages[0]["content"]!.hasSuffix("- Use British spelling."))
        XCTAssertEqual(messages[1]["content"], "The text will be inserted into Slack.\n\n<transcript>\num hello world\n</transcript>")
    }

    func testAnthropicRequest() async throws {
        let client = FakeHTTPClient { _ in (200, #"{"content":[{"type":"text","text":"Hi there."}],"stop_reason":"end_turn"}"#) }
        let cleaner = LLMCleaner(chat: AnthropicChat(apiKey: "sk-ant", model: "claude-haiku-4-5", client: client))
        let output = try await cleaner.clean("uh hi there", context: CleanupContext())
        XCTAssertEqual(output, "Hi there.")
        let request = try XCTUnwrap(client.requests.first)
        XCTAssertEqual(request.url?.absoluteString, "https://api.anthropic.com/v1/messages")
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-api-key"), "sk-ant")
        XCTAssertEqual(request.value(forHTTPHeaderField: "anthropic-version"), "2023-06-01")
        let body = jsonBody(request)
        XCTAssertEqual(body["model"] as? String, "claude-haiku-4-5")
        XCTAssertNotNil(body["system"] as? String)
        XCTAssertNotNil(body["max_tokens"] as? Int)
    }
}

final class PipelineTests: XCTestCase {
    let speech: [Float] = (0..<16_000).map { sin(Float($0) / 10) * 0.2 }

    func testCleansTranscript() async throws {
        let pipeline = DictationPipeline(
            transcriber: FakeTranscriber(text: " um so I think we should, uh, ship it [BLANK_AUDIO] "),
            cleaner: FakeCleaner { _ in "\"So I think we should ship it.\"" },
            language: "en", prompt: nil)
        let result = try await pipeline.run(samples: speech, context: CleanupContext())
        XCTAssertEqual(result.transcript, "um so I think we should, uh, ship it")
        XCTAssertEqual(result.text, "So I think we should ship it.")
        XCTAssertNil(result.cleanupProblem)
    }

    func testNoCleanerInsertsTranscript() async throws {
        let pipeline = DictationPipeline(transcriber: FakeTranscriber(text: "hello"), cleaner: nil, language: nil, prompt: nil)
        let result = try await pipeline.run(samples: speech, context: CleanupContext())
        XCTAssertEqual(result.text, "hello")
    }

    func testCleanupFailureFallsBackToTranscript() async throws {
        struct Offline: Error {}
        let pipeline = DictationPipeline(transcriber: FakeTranscriber(text: "hello there"),
                                         cleaner: FakeCleaner { _ in throw Offline() }, language: nil, prompt: nil)
        let result = try await pipeline.run(samples: speech, context: CleanupContext())
        XCTAssertEqual(result.text, "hello there")
        XCTAssertNotNil(result.cleanupProblem)
    }

    func testCleanupThatAnswersInsteadIsRejected() async throws {
        let pipeline = DictationPipeline(
            transcriber: FakeTranscriber(text: "what is the capital of France"),
            cleaner: FakeCleaner { _ in "The capital of France is Paris. It has been the capital since the 10th century and is known for the Eiffel Tower and the Louvre." },
            language: nil, prompt: nil)
        let result = try await pipeline.run(samples: speech, context: CleanupContext())
        XCTAssertEqual(result.text, "what is the capital of France")
        XCTAssertEqual(result.cleanupProblem, "Cleanup ignored: output much longer than the dictation")
    }

    func testHallucinationYieldsNothing() async throws {
        let pipeline = DictationPipeline(transcriber: FakeTranscriber(text: " Thanks for watching!"),
                                         cleaner: FakeCleaner { _ in XCTFail("should not clean"); return "" },
                                         language: nil, prompt: nil)
        let result = try await pipeline.run(samples: speech, context: CleanupContext())
        XCTAssertEqual(result.text, "")
    }

    func testCancellingDuringCleanupThrows() async {
        let pipeline = DictationPipeline(
            transcriber: FakeTranscriber(text: "hello"),
            cleaner: FakeCleaner { _ in try await Task.sleep(nanoseconds: 5_000_000_000); return "Hello." },
            language: nil, prompt: nil)
        let task = Task { try await pipeline.run(samples: speech, context: CleanupContext()) }
        try? await Task.sleep(nanoseconds: 100_000_000)
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("expected cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
    }

    func testConfigBuildsPipeline() throws {
        var config = Config()
        config.transcription.language = "auto"
        config.transcription.vocabulary = ["Murmur", "", "whisper.cpp"]
        let pipeline = try DictationPipeline(config: config, env: ["GROQ_API_KEY": "g"])
        XCTAssertNil(pipeline.language)
        XCTAssertEqual(pipeline.prompt, "Murmur, whisper.cpp.")
        XCTAssertEqual(pipeline.cleaner?.name, "Groq llama-3.3-70b-versatile")
    }
}

final class CleanupGuardTests: XCTestCase {
    func testAcceptsNormalCleanup() {
        XCTAssertEqual(CleanupGuard.check(raw: "um so like I was thinking we could uh meet tomorrow",
                                          cleaned: "So I was thinking we could meet tomorrow."),
                       .accept("So I was thinking we could meet tomorrow."))
    }

    func testEmptyOutput() {
        XCTAssertEqual(CleanupGuard.check(raw: "Um, uh... hmm.", cleaned: ""), .accept(""))
        XCTAssertEqual(CleanupGuard.check(raw: "this is a real sentence with content", cleaned: ""), .reject(reason: "empty output"))
        XCTAssertEqual(CleanupGuard.check(raw: "Sounds good to me.", cleaned: ""), .reject(reason: "empty output"),
                       "a short real dictation is not dropped when the model returns nothing")
    }

    func testRejectsSummary() {
        let raw = "so what I want to do next week is go through all of the open bugs and triage them one by one with the team"
        XCTAssertEqual(CleanupGuard.check(raw: raw, cleaned: "Triage bugs next week."),
                       .reject(reason: "output less than half the dictation"))
    }

    func testUnwrap() {
        XCTAssertEqual(CleanupPrompt.unwrap("<transcript>\nHi.\n</transcript>", raw: "hi"), "Hi.")
        XCTAssertEqual(CleanupPrompt.unwrap("\"Hi.\"", raw: "hi"), "Hi.")
        XCTAssertEqual(CleanupPrompt.unwrap("\"Hi,\" she said.", raw: "hi she said"), "\"Hi,\" she said.")
        XCTAssertEqual(CleanupPrompt.unwrap("\"quoted\"", raw: "\"quoted\""), "\"quoted\"")
        XCTAssertEqual(CleanupPrompt.unwrap("\"Yes\" and \"no\"", raw: "yes and no"), "\"Yes\" and \"no\"",
                       "two quoted phrases are not a wrapper")
        XCTAssertEqual(CleanupPrompt.unwrap("“Hi.”", raw: "hi"), "Hi.")
        XCTAssertEqual(CleanupPrompt.unwrap("“A” or “B”", raw: "a or b"), "“A” or “B”")
    }
}
