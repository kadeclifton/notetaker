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
        XCTAssertEqual(found, LocalLLM(server: "Ollama", baseURL: URL(string: "http://127.0.0.1:11434/v1")!, models: ["llama3.2:3b"]))
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
