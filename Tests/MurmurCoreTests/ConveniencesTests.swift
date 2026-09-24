import XCTest
@testable import MurmurCore

final class RecentDictationsTests: XCTestCase {
    func testNewestFirstCappedAndDeduplicated() {
        var recent = RecentDictations(limit: 3)
        recent.add("one", mode: .dictate)
        recent.add("  ", mode: .dictate)
        recent.add("two", mode: .clean)
        recent.add("three", mode: .compose)
        recent.add("four", mode: .dictate)
        XCTAssertEqual(recent.items.map(\.text), ["four", "three", "two"])
        recent.add("two", mode: .clean)
        XCTAssertEqual(recent.items.map(\.text), ["two", "four", "three"], "repeats move to the top")
        recent.clear()
        XCTAssertTrue(recent.items.isEmpty)
    }

    func testPreview() {
        var recent = RecentDictations()
        recent.add("Hi Sam,\n\n  The launch   moves to Friday so that QA can finish the regression pass properly.", mode: .compose)
        XCTAssertEqual(recent.items[0].preview, "Hi Sam, The launch moves to Friday so that QA can finish…")
    }
}

final class TextTargetTests: XCTestCase {
    func testVerdicts() {
        XCTAssertEqual(TextTarget.verdict(role: "AXTextArea", editable: nil), .text)
        XCTAssertEqual(TextTarget.verdict(role: "AXWebArea", editable: nil), .text, "unknown roles still get the paste")
        XCTAssertEqual(TextTarget.verdict(role: "AXList", editable: false), .notText)
        XCTAssertEqual(TextTarget.verdict(role: "AXGroup", editable: true), .text, "editable wins over the role")
        XCTAssertEqual(TextTarget.verdict(role: nil, editable: nil), .text, "Chrome and Electron often report nothing")
        XCTAssertEqual(TextTarget.verdict(role: "AXWindow", editable: nil), .text, "or only their window")
        XCTAssertEqual(TextTarget.verdict(role: "AXButton", editable: nil), .notText)
    }
}

final class SpeechModelChoiceTests: XCTestCase {
    func testByMemory() {
        let gib: UInt64 = 1_073_741_824
        XCTAssertEqual(WhisperModelOption.recommended(memoryBytes: 8 * gib), .base)
        XCTAssertEqual(WhisperModelOption.recommended(memoryBytes: 16 * gib), .small)
    }

    func testIdleUnloadSetting() throws {
        XCTAssertEqual(Config().transcription.whisperCpp.unloadAfterMinutes, 30)
        XCTAssertEqual(try Config.parse(Config.defaultFileContents), Config())
    }
}

final class VocabularyEditTests: XCTestCase {
    func testReplacesTheList() throws {
        let edited = try XCTUnwrap(ConfigFileEdit.settingVocabulary(["Kubernetes", #"O"Brien"#], in: Config.defaultFileContents))
        XCTAssertEqual(try Config.parse(edited).transcription.vocabulary, ["Kubernetes", #"O"Brien"#])
        XCTAssertTrue(edited.contains("// Names and jargon Whisper keeps getting wrong."), "comments survive")
        let back = try XCTUnwrap(ConfigFileEdit.settingVocabulary([], in: edited))
        XCTAssertEqual(try Config.parse(back).transcription.vocabulary, [])
    }

    func testAddsTheKeyWhenMissing() throws {
        let text = #"{ "transcription": { "engine": "local", "whisperCpp": { "threads": 4 } } }"#
        let edited = try XCTUnwrap(ConfigFileEdit.settingVocabulary(["Murmur"], in: text))
        let config = try Config.parse(edited)
        XCTAssertEqual(config.transcription.vocabulary, ["Murmur"])
        XCTAssertEqual(config.transcription.whisperCpp.threads, 4)
        XCTAssertEqual(try Config.parse(XCTUnwrap(ConfigFileEdit.settingVocabulary(["A"], in: "{}"))).transcription.vocabulary, ["A"])
    }
}

final class ThinkingPreferenceTests: XCTestCase {
    override func setUp() { ThinkingModels.shared.removeAll() }
    override func tearDown() { ThinkingModels.shared.removeAll() }

    func testNonThinkingBuildsWinWhenThereIsAChoice() {
        let gib: UInt64 = 1_073_741_824
        let local = LocalLLM(server: "Ollama", baseURL: URL(string: "http://127.0.0.1:11434/v1")!,
                             models: ["qwen3:30b-a3b-thinking-2507-q4_K_M", "qwen3:30b-a3b-instruct-2507-q4_K_M", "qwen3:4b"],
                             sizes: ["qwen3:30b-a3b-thinking-2507-q4_K_M": 18_600_000_000,
                                     "qwen3:30b-a3b-instruct-2507-q4_K_M": 18_600_000_000, "qwen3:4b": 2_600_000_000])
        XCTAssertEqual(local.pickModel(for: .compose, memoryBytes: 36 * gib), "qwen3:30b-a3b-instruct-2507-q4_K_M")
    }

    func testModelsSeenThinkingAreAvoided() {
        let gib: UInt64 = 1_073_741_824
        let local = LocalLLM(server: "Ollama", baseURL: URL(string: "http://127.0.0.1:11434/v1")!,
                             models: ["qwen3:30b", "qwen3:8b"], sizes: ["qwen3:30b": 18_600_000_000, "qwen3:8b": 5_200_000_000])
        XCTAssertEqual(local.pickModel(for: .compose, memoryBytes: 36 * gib), "qwen3:30b")
        ThinkingModels.shared.insert("qwen3:30b")
        XCTAssertEqual(local.pickModel(for: .compose, memoryBytes: 36 * gib), "qwen3:8b")
        let onlyThinking = LocalLLM(server: "Ollama", baseURL: local.baseURL, models: ["qwen3:30b"], sizes: ["qwen3:30b": 18_600_000_000])
        XCTAssertEqual(onlyThinking.pickModel(for: .compose, memoryBytes: 36 * gib), "qwen3:30b", "still used when it is all there is")
    }

    func testRememberedAcrossLaunches() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "murmur-tests-\(UUID().uuidString)"))
        ThinkingModels(defaults: defaults).insert("qwen3:30b")
        XCTAssertTrue(ThinkingModels(defaults: defaults).contains("qwen3:30b"))
        XCTAssertFalse(ThinkingModels(defaults: nil).contains("qwen3:30b"))
    }
}

final class PipelineStageTests: XCTestCase {
    final class Stages: @unchecked Sendable {
        private let lock = NSLock()
        private var _list: [DictationPipeline.Stage] = []
        var list: [DictationPipeline.Stage] { lock.withLock { _list } }
        func add(_ stage: DictationPipeline.Stage) { lock.withLock { _list.append(stage) } }
    }

    func testReportsCleanupOnlyWhenItRuns() async throws {
        let stages = Stages()
        let clean = DictationPipeline(transcriber: FakeTranscriber(text: "hello there"),
                                      cleaner: FakeCleaner { _ in "Hello there." }, language: nil, prompt: nil)
        _ = try await clean.run(samples: [0.1, 0.2], context: CleanupContext()) { stages.add($0) }
        XCTAssertEqual(stages.list, [.cleaningUp])
        let raw = DictationPipeline(transcriber: FakeTranscriber(text: "hello"), cleaner: nil, language: nil, prompt: nil)
        _ = try await raw.run(samples: [0.1], context: CleanupContext()) { stages.add($0) }
        XCTAssertEqual(stages.list, [.cleaningUp], "no cleanup, no stage change")
    }
}
