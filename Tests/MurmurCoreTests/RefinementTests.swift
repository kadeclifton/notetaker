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

final class LaunchReadinessTests: XCTestCase {
    func testPlainHTTPOnlyStaysLocal() {
        let allowed = ["https://api.example.com/v1", "http://localhost:11434/v1", "http://127.0.0.1:1234/v1",
                       "http://192.168.1.20:8080/v1", "http://10.0.0.5/v1", "http://172.20.1.1/v1", "http://studio.local:1234/v1",
                       "http://[::1]:8080/v1"]
        for url in allowed { XCTAssertTrue(NetworkSafety.isAllowed(URL(string: url)!), url) }
        let refused = ["http://api.example.com/v1", "http://8.8.8.8/v1", "http://172.32.0.1/v1", "ftp://localhost/x"]
        for url in refused { XCTAssertFalse(NetworkSafety.isAllowed(URL(string: url)!), url) }
    }

    func testCustomCleanupServerOverPlainHTTPIsRefused() {
        var config = Config()
        config.cleanup.provider = .custom
        config.cleanup.baseURL = "http://my-server.example.com/v1"
        XCTAssertThrowsError(try config.makeCleaner(env: [:])) { error in
            XCTAssertEqual(error as? SetupError, .insecureBaseURL("http://my-server.example.com/v1"))
        }
        config.cleanup.baseURL = "http://localhost:8080/v1"
        XCTAssertNoThrow(try config.makeCleaner(env: [:]))
    }

    func testUpdatesOnlyComeFromGitHubOverHTTPS() {
        XCTAssertTrue(NetworkSafety.isGitHubDownload(URL(string: "https://github.com/o/r/releases/download/v1/Murmur-v1.zip")!))
        XCTAssertTrue(NetworkSafety.isGitHubDownload(URL(string: "https://objects.githubusercontent.com/x")!))
        XCTAssertFalse(NetworkSafety.isGitHubDownload(URL(string: "http://github.com/o/r/releases/download/v1/Murmur-v1.zip")!))
        XCTAssertFalse(NetworkSafety.isGitHubDownload(URL(string: "https://github.com.evil.example/x.zip")!))
        let json = """
        {"tag_name": "v9.0.0", "html_url": "https://github.com/o/r/releases/tag/v9.0.0",
         "assets": [{"name": "Murmur-v9.0.0.zip", "browser_download_url": "http://example.com/Murmur-v9.0.0.zip"}]}
        """
        XCTAssertThrowsError(try UpdateChecker.parse(Data(json.utf8))) { error in
            XCTAssertEqual(error as? UpdateError, .untrustedDownload("http://example.com/Murmur-v9.0.0.zip"))
        }
    }

    func testSnippetValidation() {
        XCTAssertNil(VoiceCommands.problem(with: Snippet(say: "my email", insert: "me@example.com")))
        XCTAssertNotNil(VoiceCommands.problem(with: Snippet(say: "  ", insert: "x")))
        XCTAssertNotNil(VoiceCommands.problem(with: Snippet(say: "sig", insert: " \n")))
        XCTAssertNotNil(VoiceCommands.problem(with: Snippet(say: "Scratch that!", insert: "x")))
        XCTAssertNotNil(VoiceCommands.problem(with: Snippet(say: "new line", insert: "x")))
    }
}

final class NextReleaseTests: XCTestCase {
    func testShiftPicksEdit() {
        XCTAssertEqual(ModeKeys(extraModifiers: [.shift]), .shift)
        XCTAssertEqual(ModeKeys(extraModifiers: [.control, .shift]), .shift)
        XCTAssertEqual(ModeKeys(extraModifiers: [.control]), .control)
        XCTAssertEqual(Config().modes.mode(for: .shift), .edit)
        XCTAssertEqual(ModeKeys.shift.label(hotkey: "fn"), "fn⇧")
        XCTAssertTrue(ModeKeys.shift > .controlOption, "⇧ joining later still upgrades the recording")
        XCTAssertEqual(try Config.parse(Config.defaultFileContents), Config())
    }

    func testEditReplyIsCleaned() {
        XCTAssertEqual(EditPrompt.clean("<think>hmm</think>\n\"Shorter text.\"", original: "A much longer text."), "Shorter text.")
        XCTAssertEqual(EditPrompt.clean("```markdown\n- one\n- two\n```", original: "one, two"), "- one\n- two")
        XCTAssertEqual(EditPrompt.clean("<text>\nHola\n</text>", original: "Hello"), "Hola")
        XCTAssertEqual(EditPrompt.clean("\"Quoted\"", original: "\"quoted\""), "\"Quoted\"", "quotes the original had stay")
        XCTAssertTrue(EditPrompt.user(text: "Hi", instruction: "make it formal").contains("<text>\nHi\n</text>"))
    }

    func testEditorUsesTheModel() async throws {
        struct Echo: ChatModel {
            var name: String { "echo" }
            func complete(system: String, user: String, maxTokens: Int, timeout: TimeInterval) async throws -> String {
                XCTAssertTrue(user.contains("<instruction>\nshorter\n</instruction>"))
                return "Short."
            }
        }
        let edited = try await Editor(chat: Echo()).edit("A long sentence here.", instruction: "shorter")
        XCTAssertEqual(edited, "Short.")
    }

    func testDictateAndCleanOnlyGetVoiceCommands() throws {
        var config = Config()
        config.transcription.engine = .groq
        let env = ["GROQ_API_KEY": "k"]
        XCTAssertFalse(try DictationPipeline(config: config, env: env, mode: .edit).voiceCommands)
        XCTAssertNil(try DictationPipeline(config: config, env: env, mode: .edit).cleaner)
    }

    func testCallEndOffer() {
        let t0 = Date(timeIntervalSince1970: 0)
        var call = CallEndDetector(quietApps: 30, silence: 300)
        XCTAssertFalse(call.update(othersUsingMic: true, sinceSpeech: 5, now: t0))
        XCTAssertFalse(call.update(othersUsingMic: false, sinceSpeech: 10, now: t0 + 10))
        XCTAssertTrue(call.update(othersUsingMic: false, sinceSpeech: 45, now: t0 + 45), "the call app let go 35 s ago")
        XCTAssertFalse(call.update(othersUsingMic: false, sinceSpeech: 60, now: t0 + 60), "offered once")
        XCTAssertFalse(call.update(othersUsingMic: true, sinceSpeech: 1, now: t0 + 70), "back on the call")
        XCTAssertFalse(call.update(othersUsingMic: false, sinceSpeech: 5, now: t0 + 80))
        XCTAssertTrue(call.update(othersUsingMic: false, sinceSpeech: 30, now: t0 + 115))

        var room = CallEndDetector(quietApps: 30, silence: 300)
        XCTAssertFalse(room.update(othersUsingMic: false, sinceSpeech: 10, now: t0 + 100), "in-person: no call app ever used the mic")
        XCTAssertTrue(room.update(othersUsingMic: false, sinceSpeech: 301, now: t0 + 400), "but five silent minutes still count")

        var unknown = CallEndDetector(quietApps: 30, silence: 300)
        XCTAssertFalse(unknown.update(othersUsingMic: nil, sinceSpeech: 200, now: t0))
        XCTAssertTrue(unknown.update(othersUsingMic: nil, sinceSpeech: 300, now: t0 + 100))
    }

    func testStats() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        var stats = UsageStats()
        stats.record(words: 400, spoken: 120, on: now, calendar: calendar)
        stats.record(words: 0, spoken: 5, on: now, calendar: calendar)
        stats.record(words: 100, spoken: 30, on: now.addingTimeInterval(-3 * 86400), calendar: calendar)
        stats.record(words: 50, spoken: 10, on: now.addingTimeInterval(-10 * 86400), calendar: calendar)
        let week = stats.summary(lastDays: 7, now: now, calendar: calendar)
        XCTAssertEqual(week.words, 500)
        XCTAssertEqual(week.dictations, 2)
        XCTAssertEqual(week.minutesSaved, 500.0 / 40 - 150.0 / 60, accuracy: 0.001)
        XCTAssertEqual(stats.summary(lastDays: 30, now: now, calendar: calendar).words, 550)
        stats.record(words: 1, spoken: 1, on: now.addingTimeInterval(95 * 86400), calendar: calendar)
        XCTAssertEqual(stats.days.count, 1, "older than 90 days is dropped")
        XCTAssertEqual(UsageStats.wordCount("Hi Sam,\nthanks  for it"), 5)
    }
}

final class SelectionCopyTests: XCTestCase {
    func testLineCopiesInCodeEditorsAreNotSelections() {
        let vscode = "com.microsoft.VSCode"
        XCTAssertFalse(SelectionCopy.accept("let x = 1\n", bundleID: vscode), "VS Code copied the line: nothing was selected")
        XCTAssertTrue(SelectionCopy.accept("let x = 1", bundleID: vscode), "a real selection within the line")
        XCTAssertTrue(SelectionCopy.accept("one\ntwo\n", bundleID: vscode), "several selected lines")
        XCTAssertFalse(SelectionCopy.accept("x\n", bundleID: "com.jetbrains.intellij"))
        XCTAssertTrue(SelectionCopy.accept("Hello there\n", bundleID: "com.apple.Notes"), "other apps copy only selections")
        XCTAssertFalse(SelectionCopy.accept("", bundleID: "com.apple.Notes"))
    }
}
