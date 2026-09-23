import XCTest
@testable import MurmurCore

final class AudioTests: XCTestCase {
    func testWavHeader() {
        let data = Audio.wav(samples: [0, 1, -1, 0.5])
        XCTAssertEqual(data.count, 44 + 8)
        XCTAssertEqual(String(decoding: data[0..<4], as: UTF8.self), "RIFF")
        XCTAssertEqual(String(decoding: data[8..<16], as: UTF8.self), "WAVEfmt ")
        func u32(_ at: Int) -> UInt32 { data[at..<at + 4].reversed().reduce(0) { $0 << 8 | UInt32($1) } }
        func i16(_ at: Int) -> Int16 { Int16(bitPattern: UInt16(data[at + 1]) << 8 | UInt16(data[at])) }
        XCTAssertEqual(u32(4), 36 + 8)
        XCTAssertEqual(u32(24), 16_000)
        XCTAssertEqual(u32(40), 8)
        XCTAssertEqual([i16(44), i16(46), i16(48), i16(50)], [0, 32767, -32767, 16384])
    }

    func testSilence() {
        XCTAssertTrue(Audio.isSilent([Float](repeating: 0.001, count: 16_000)))
        var samples = [Float](repeating: 0, count: 16_000)
        for i in 8_000..<8_800 { samples[i] = i.isMultiple(of: 2) ? 0.05 : -0.05 }
        XCTAssertFalse(Audio.isSilent(samples))
        XCTAssertEqual(Audio.duration(of: samples), 1)
    }

    func testTranscriptFilter() {
        XCTAssertEqual(TranscriptFilter.clean(" [BLANK_AUDIO] "), "")
        XCTAssertEqual(TranscriptFilter.clean("Hello [Music] world\n again"), "Hello world again")
        XCTAssertEqual(TranscriptFilter.clean("Thanks for watching!"), "")
        XCTAssertEqual(TranscriptFilter.clean("Thank you."), "Thank you.")
    }
}

final class WhisperCppTests: XCTestCase {
    var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    func script(_ body: String) throws -> String {
        let url = dir.appendingPathComponent("whisper-cli")
        try "#!/bin/sh\n\(body)\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url.path
    }

    func model() throws -> String {
        let url = dir.appendingPathComponent("ggml-small.en.bin")
        try Data().write(to: url)
        return url.path
    }

    func testRunsCliAndJoinsLines() async throws {
        // Echo the arguments so we can check them, then print what whisper-cli would.
        let binary = try script("""
        echo "$@" > "$(dirname "$0")/args.txt"
        echo " Hello there."
        echo ""
        echo " How are you?"
        """)
        let transcriber = WhisperCppTranscriber(binary: binary, model: try model(), threads: 4)
        let text = try await transcriber.transcribe(wav: Audio.wav(samples: [0]), language: "en", prompt: "Murmur.")
        XCTAssertEqual(text, "Hello there. How are you?")
        let args = try String(contentsOf: dir.appendingPathComponent("args.txt"), encoding: .utf8)
        XCTAssertTrue(args.contains("-m \(dir.path)/ggml-small.en.bin -f "))
        XCTAssertTrue(args.contains("-t 4 --no-timestamps --no-prints -l en --prompt Murmur."))
    }

    func testFailureReportsStderr() async throws {
        let binary = try script("echo 'failed to load model' >&2; exit 3")
        let transcriber = WhisperCppTranscriber(binary: binary, model: try model())
        do {
            _ = try await transcriber.transcribe(wav: Data(), language: nil, prompt: nil)
            XCTFail("expected failure")
        } catch {
            XCTAssertEqual(error as? TranscriptionError, .whisperFailed(status: 3, output: "failed to load model"))
        }
    }

    func testMissingModel() async throws {
        let transcriber = WhisperCppTranscriber(binary: try script("exit 0"), model: dir.appendingPathComponent("nope.bin").path)
        do {
            _ = try await transcriber.transcribe(wav: Data(), language: nil, prompt: nil)
            XCTFail("expected failure")
        } catch {
            XCTAssertEqual(error as? TranscriptionError, .modelNotFound(dir.appendingPathComponent("nope.bin").path))
        }
    }

    func testCancelKillsTheProcess() async throws {
        let binary = try script("exec sleep 30")
        let transcriber = WhisperCppTranscriber(binary: binary, model: try model())
        let start = Date()
        let task = Task { try await transcriber.transcribe(wav: Data(), language: nil, prompt: nil) }
        try await Task.sleep(nanoseconds: 300_000_000)
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("expected cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError, "got \(error)")
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), 5)
    }

    func testLocateBinary() throws {
        let binary = try script("exit 0")
        XCTAssertEqual(WhisperCppTranscriber.locateBinary(configured: binary), binary)
        XCTAssertNil(WhisperCppTranscriber.locateBinary(configured: dir.appendingPathComponent("missing").path))
        XCTAssertEqual(WhisperCppTranscriber.locateBinary(configured: "", environment: ["PATH": "/nowhere:\(dir.path)"]), binary)
    }
}
