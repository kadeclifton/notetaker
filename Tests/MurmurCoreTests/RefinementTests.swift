import XCTest
@testable import MurmurCore

final class TrimSilenceTests: XCTestCase {
    func testTrimsLeadingAndTrailingSilenceWithPadding() {
        let rate = Audio.sampleRate
        let silence = [Float](repeating: 0, count: rate * 2)
        let speech = (0..<rate).map { Float(sin(Double($0) * 0.1)) * 0.2 }
        let trimmed = Audio.trimmingSilence(silence + speech + silence)
        XCTAssertEqual(Double(trimmed.count) / Double(rate), 1.6, accuracy: 0.05)
        XCTAssertEqual(Audio.trimmingSilence(silence), silence, "all silence stays as is")
        XCTAssertEqual(Audio.trimmingSilence(speech), speech)
    }
}

final class FormattingTests: XCTestCase {
    func testNewLineAndParagraph() {
        XCTAssertEqual(VoiceCommands.applyFormatting("Hi Sam, new line. Thanks for the notes."), "Hi Sam\nThanks for the notes.")
        XCTAssertEqual(VoiceCommands.applyFormatting("That's the plan. New paragraph. next steps are simple."),
                       "That's the plan.\n\nNext steps are simple.")
        XCTAssertEqual(VoiceCommands.applyFormatting("New line, hello"), "Hello")
        XCTAssertEqual(VoiceCommands.applyFormatting("A brand new lineup is out."), "A brand new lineup is out.")
        XCTAssertEqual(VoiceCommands.applyFormatting("No commands here."), "No commands here.")
    }
}

/// Answers with a numbered piece per request, so order and prompts can be checked.
final class CountingTranscriber: Transcriber, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private(set) var prompts: [String?] = []
    var name: String { "counting" }

    func transcribe(wav: Data, language: String?, prompt: String?) async throws -> String {
        let n = lock.withLock { () -> Int in
            count += 1
            prompts.append(prompt)
            return count
        }
        return "piece\(n)."
    }

    var calls: Int { lock.withLock { count } }
}

final class IncrementalTests: XCTestCase {
    private func speech(seconds: Double) -> [Float] {
        (0..<Int(seconds * Double(Audio.sampleRate))).map { Float(sin(Double($0) * 0.05)) * 0.2 }
    }

    func testShortRecordingIsLeftToTheCaller() async throws {
        let transcriber = CountingTranscriber()
        let incremental = IncrementalTranscription(transcriber: transcriber, language: "en", prompt: nil, chunkSeconds: 10)
        await incremental.append(speech(seconds: 4))
        let early = try await incremental.finish()
        XCTAssertNil(early)
        XCTAssertEqual(transcriber.calls, 0)
    }

    func testLongRecordingIsTranscribedInOrderWithContext() async throws {
        let transcriber = CountingTranscriber()
        let incremental = IncrementalTranscription(transcriber: transcriber, language: "en", prompt: "Kubernetes.", chunkSeconds: 10)
        for _ in 0..<5 { await incremental.append(speech(seconds: 5)) }  // 25 s: two cuts, then the rest
        let text = try await incremental.finish()
        XCTAssertEqual(text, "piece1. piece2. piece3.")
        XCTAssertEqual(transcriber.prompts.first!, "Kubernetes.")
        XCTAssertEqual(transcriber.prompts.last!, "Kubernetes. piece1. piece2.")
    }

    func testPipelineUsesTheEarlyTranscript() async throws {
        let transcriber = CountingTranscriber()
        let incremental = IncrementalTranscription(transcriber: transcriber, language: nil, prompt: nil, chunkSeconds: 10)
        let audio = speech(seconds: 22)
        await incremental.append(audio)
        let pipeline = DictationPipeline(transcriber: transcriber, cleaner: nil, language: nil, prompt: nil)
        let result = try await pipeline.run(samples: audio, incremental: incremental, context: CleanupContext())
        XCTAssertEqual(result.text, "piece1. piece2. piece3.")
        XCTAssertEqual(transcriber.calls, 3, "the whole clip is not transcribed again")
    }

    func testShortPhrasesSkipCleanup() async throws {
        let cleaner = FakeCleaner { _ in "Cleaned up text here." }
        let short = DictationPipeline(transcriber: FakeTranscriber(text: "Sounds good."), cleaner: cleaner, language: nil, prompt: nil)
        let result = try await short.run(samples: speech(seconds: 1), context: CleanupContext())
        XCTAssertEqual(result.text, "Sounds good.")
        XCTAssertNil(result.cleanupSeconds)
        let long = DictationPipeline(transcriber: FakeTranscriber(text: "so um I think we should ship it"), cleaner: cleaner,
                                     language: nil, prompt: nil)
        let cleaned = try await long.run(samples: speech(seconds: 1), context: CleanupContext())
        XCTAssertNotNil(cleaned.cleanupSeconds)
    }
}
