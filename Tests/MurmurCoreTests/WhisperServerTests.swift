import XCTest
@testable import MurmurCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

final class FakeWhisperServer: WhisperServing, @unchecked Sendable {
    let baseURL = URL(string: "http://127.0.0.1:47813")!
    private let lock = NSLock()
    private var _starts = 0
    var starts: Int { lock.withLock { _starts } }
    func ensureRunning() async throws { lock.withLock { _starts += 1 } }
}

final class WhisperServerTests: XCTestCase {
    var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    func executable(_ name: String, _ body: String) throws -> String {
        let url = dir.appendingPathComponent(name)
        try "#!/bin/sh\n\(body)\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url.path
    }

    func testInferenceRequest() async throws {
        let server = FakeWhisperServer()
        let client = FakeHTTPClient { _ in (200, #"{"text":" Hello there.\n"}"#) }
        let transcriber = WhisperServerTranscriber(server: server, modelName: "ggml-small.en", client: client)
        let text = try await transcriber.transcribe(wav: Data([1, 2]), language: "en", prompt: "Murmur.")
        XCTAssertEqual(text, " Hello there.\n")
        XCTAssertEqual(server.starts, 1)
        XCTAssertEqual(transcriber.name, "whisper.cpp (ggml-small.en, kept loaded)")
        let request = try XCTUnwrap(client.requests.first)
        XCTAssertEqual(request.url?.absoluteString, "http://127.0.0.1:47813/inference")
        let body = String(decoding: request.httpBody ?? Data(), as: UTF8.self)
        XCTAssertTrue(body.contains("name=\"response_format\"\r\n\r\nverbose_json\r\n"))
        XCTAssertTrue(body.contains("name=\"language\"\r\n\r\nen\r\n"))
        XCTAssertTrue(body.contains("name=\"prompt\"\r\n\r\nMurmur.\r\n"))
    }

    func testSegmentsCarryTimestamps() async throws {
        let client = FakeHTTPClient { _ in
            (200, #"{"task":"transcribe","language":"en","duration":6.2,"text":" Hi. How are you?","segments":[{"id":0,"start":0.0,"end":1.4,"text":" Hi."},{"id":1,"start":2.0,"end":6.2,"text":" How are you?"}]}"#)
        }
        let transcriber = WhisperServerTranscriber(server: FakeWhisperServer(), modelName: "m", client: client)
        let segments = try await transcriber.transcribeSegments(wav: Data(), language: nil, prompt: nil)
        XCTAssertEqual(segments, [TimedText(start: 0, end: 1.4, text: " Hi."), TimedText(start: 2, end: 6.2, text: " How are you?")])
    }

    func testDefaultSegmentsIsTheWholeClip() async throws {
        let segments = try await FakeTranscriber(text: "hello").transcribeSegments(
            wav: Audio.wav(samples: [Float](repeating: 0, count: 32_000)), language: nil, prompt: nil)
        XCTAssertEqual(segments, [TimedText(start: 0, end: 2, text: "hello")])
    }

    func testRestartsAServerThatDied() async throws {
        let server = FakeWhisperServer()
        let calls = Counter()
        let client = FakeHTTPClient { _ in
            if calls.next() == 1 { throw URLError(.cannotConnectToHost) }
            return (200, #"{"text":"ok"}"#)
        }
        let transcriber = WhisperServerTranscriber(server: server, modelName: "m", client: client)
        let text = try await transcriber.transcribe(wav: Data(), language: nil, prompt: nil)
        XCTAssertEqual(text, "ok")
        XCTAssertEqual(server.starts, 2)
    }

    func testServerThatExitsReportsItsLog() async throws {
        let binary = try executable("whisper-server", "echo 'error: failed to bind port' >&2; exit 1")
        let model = dir.appendingPathComponent("ggml-small.en.bin")
        try Data().write(to: model)
        let server = WhisperServer(.init(binary: binary, model: model.path, port: 47999, threads: 2,
                                         language: "en", stateDirectory: dir),
                                   client: FakeHTTPClient { _ in throw URLError(.cannotConnectToHost) })
        do {
            try await server.ensureRunning()
            XCTFail("expected failure")
        } catch let error as WhisperServerError {
            XCTAssertEqual(error, .exited(log: "error: failed to bind port"))
        }
        server.stop()
    }

    func testServerComesUpWhenItAnswers() async throws {
        let binary = try executable("whisper-server", "echo \"$@\" > \"$(dirname \"$0\")/args.txt\"; exec sleep 30")
        let model = dir.appendingPathComponent("ggml-small.en.bin")
        try Data().write(to: model)
        let server = WhisperServer(.init(binary: binary, model: model.path, port: 47999, threads: 3,
                                         language: "en", stateDirectory: dir),
                                   client: FakeHTTPClient { _ in (200, "<html>whisper.cpp</html>") })
        try await server.ensureRunning()
        try await server.ensureRunning() // already up: no second process
        // The fake answers health checks at once, so the script may still be writing its args.
        let argsFile = dir.appendingPathComponent("args.txt")
        for _ in 0..<50 where (try? String(contentsOf: argsFile, encoding: .utf8))?.isEmpty ?? true {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        let args = try String(contentsOf: argsFile, encoding: .utf8)
        XCTAssertEqual(args.trimmingCharacters(in: .whitespacesAndNewlines),
                       "-m \(model.path) --host 127.0.0.1 --port 47999 -t 3 -l en")
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("whisper-server.pid").path))
        server.stop()
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("whisper-server.pid").path))
    }

    func testMissingModel() async {
        let server = WhisperServer(.init(binary: "/bin/sh", model: dir.appendingPathComponent("none.bin").path,
                                         port: 47999, threads: 1, language: "en", stateDirectory: dir))
        do {
            try await server.ensureRunning()
            XCTFail("expected failure")
        } catch {
            XCTAssertEqual(error as? TranscriptionError, .modelNotFound(dir.appendingPathComponent("none.bin").path))
        }
    }

    func testConfigPrefersTheServerWhenInstalled() throws {
        let cli = try executable("whisper-cli", "exit 0")
        _ = try executable("whisper-server", "exit 0")
        var config = Config()
        config.transcription.engine = .local
        config.transcription.whisperCpp.binary = cli
        XCTAssertTrue(try config.makeTranscriber(env: [:]) is WhisperServerTranscriber)
        config.transcription.whisperCpp.keepModelLoaded = false
        XCTAssertTrue(try config.makeTranscriber(env: [:]) is WhisperCppTranscriber)
        XCTAssertEqual(WhisperCppTranscriber.locateServer(configuredCli: "", environment: ["PATH": dir.path]),
                       dir.appendingPathComponent("whisper-server").path)
    }
}

final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func next() -> Int { lock.withLock { value += 1; return value } }
}
