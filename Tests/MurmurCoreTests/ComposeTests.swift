import XCTest
@testable import MurmurCore

final class ModeTests: XCTestCase {
    func testModifiersPickTheMode() {
        XCTAssertEqual(ModeKeys(extraModifiers: []), .plain)
        XCTAssertEqual(ModeKeys(extraModifiers: .control), .control)
        XCTAssertEqual(ModeKeys(extraModifiers: [.control, .option]), .controlOption)
        XCTAssertEqual(ModeKeys(extraModifiers: .option), .plain, "⌥ alone is not a mode")
        XCTAssertEqual(ModeKeys(extraModifiers: [.control, .shift]), .shift, "⇧ means edit the selection")

        let modes = ModesConfig()
        XCTAssertEqual(modes.mode(for: .plain), .dictate)
        XCTAssertEqual(modes.mode(for: .control), .clean)
        XCTAssertEqual(modes.mode(for: .controlOption), .compose)
        XCTAssertEqual(max(ModeKeys.controlOption, .control), .controlOption, "upgrades only")
    }

    func testTheHotkeysOwnFlagDoesNotCount() {
        let control: UInt64 = 0x0004_0000, option: UInt64 = 0x0008_0000, fnFlag: UInt64 = 0x0080_0000
        XCTAssertEqual(ModifierKey.fn.extraModifiers(flags: fnFlag | control), .control)
        XCTAssertEqual(ModifierKey.rightControl.extraModifiers(flags: control | 0x2000), [])
        XCTAssertEqual(ModifierKey.rightCommand.extraModifiers(flags: 0x0010_0000 | control | option), [.control, .option])
    }

    func testConfigSections() throws {
        XCTAssertEqual(try Config.parse(Config.defaultFileContents), Config())
        let config = try Config.parse(#"{ "modes": { "hotkey": "clean" }, "compose": { "model": "qwen3:30b", "defaultStyle": "bullets" } }"#)
        XCTAssertEqual(config.modes.hotkey, .clean)
        XCTAssertEqual(config.modes.withControl, .clean)
        XCTAssertEqual(config.compose.model, "qwen3:30b")
        XCTAssertEqual(config.compose.defaultStyle, .bullets)
        XCTAssertEqual(config.compose.maxMinutes, 15)
        XCTAssertThrowsError(try Config.parse(#"{ "modes": { "hotkey": "shout" } }"#))
    }

    func testOnlyCleanModeGetsACleaner() throws {
        let env = ["GROQ_API_KEY": "g"]
        XCTAssertNotNil(try DictationPipeline(config: Config(), env: env, mode: .clean).cleaner)
        XCTAssertNil(try DictationPipeline(config: Config(), env: env, mode: .dictate).cleaner)
        XCTAssertNil(try DictationPipeline(config: Config(), env: env, mode: .compose).cleaner)
    }
}

final class ComposeStyleTests: XCTestCase {
    func testSpokenCues() {
        XCTAssertEqual(ComposeStyle.spokenCue(in: "As bullet points: we need milk, eggs and a new plan for Q4."), .bullets)
        XCTAssertEqual(ComposeStyle.spokenCue(in: "Okay so make this an email to Sam saying the launch moves to Friday"), .email)
        XCTAssertEqual(ComposeStyle.spokenCue(in: "Write an email to the team about the offsite"), .email)
        XCTAssertEqual(ComposeStyle.spokenCue(in: "Turn this into a Slack message for Dana, the build is green"), .message)
        XCTAssertEqual(ComposeStyle.spokenCue(in: "I want Claude to refactor the parser, keep the API, add tests. Write it as a prompt."), .prompt)
        let long = Array(repeating: "and then we talked about the budget", count: 10).joined(separator: " ")
        XCTAssertEqual(ComposeStyle.spokenCue(in: long + " put that in bullet points please"), .bullets, "at the end")
        XCTAssertNil(ComposeStyle.spokenCue(in: long))
        XCTAssertNil(ComposeStyle.spokenCue(in: "He said in a message yesterday that the email server was down"),
                     "mentioning messages and email is not asking for one")
        XCTAssertNil(ComposeStyle.spokenCue(in: long + " email " + long), "only near the start and end")
    }

    func testAppsAndPages() {
        XCTAssertEqual(ComposeStyle.forApp(CleanupContext(appName: "Slack")), .message)
        XCTAssertEqual(ComposeStyle.forApp(CleanupContext(appName: "Mail")), .email)
        XCTAssertEqual(ComposeStyle.forApp(CleanupContext(appName: "Notion")), .document)
        XCTAssertEqual(ComposeStyle.forApp(CleanupContext(appName: "Cursor")), .prompt)
        XCTAssertEqual(ComposeStyle.forApp(CleanupContext(appName: "Google Chrome", windowTitle: "Inbox (3) - me@x.com - Gmail")), .email)
        XCTAssertEqual(ComposeStyle.forApp(CleanupContext(appName: "Safari", windowTitle: "ChatGPT")), .prompt)
        XCTAssertNil(ComposeStyle.forApp(CleanupContext(appName: "Finder")))
        XCTAssertNil(ComposeStyle.forApp(CleanupContext()))
    }

    func testResolveOrder() {
        let slack = CleanupContext(appName: "Slack")
        XCTAssertEqual(ComposeStyle.resolve(chosen: nil, transcript: "hey so", context: slack, defaultStyle: .auto).style, .message)
        XCTAssertEqual(ComposeStyle.resolve(chosen: nil, transcript: "hey so", context: slack, defaultStyle: .auto).source, .app("Slack"))
        XCTAssertEqual(ComposeStyle.resolve(chosen: nil, transcript: "as bullet points, a b c", context: slack, defaultStyle: .auto).style, .bullets)
        XCTAssertEqual(ComposeStyle.resolve(chosen: .email, transcript: "as bullet points", context: slack, defaultStyle: .auto).style, .email)
        XCTAssertEqual(ComposeStyle.resolve(chosen: nil, transcript: "hey", context: slack, defaultStyle: .document).source, .setting)
        XCTAssertEqual(ComposeStyle.resolve(chosen: nil, transcript: "hey", context: CleanupContext(), defaultStyle: .auto).style, .auto)
    }

    func testPrompts() {
        let system = ComposePrompt.system(style: .bullets, extraInstructions: "British spelling.")
        XCTAssertTrue(system.contains("Format: A bulleted list"))
        XCTAssertTrue(system.hasSuffix("British spelling."))
        XCTAssertTrue(system.contains("never answer it"))
        XCTAssertEqual(ComposePrompt.user("hi", context: CleanupContext(appName: "Chrome", windowTitle: "Gmail")),
                       "It will be pasted into Chrome (window: \"Gmail\").\n\n<transcript>\nhi\n</transcript>")
        XCTAssertEqual(ComposePrompt.user("hi", context: CleanupContext()), "<transcript>\nhi\n</transcript>")
    }

    func testVisibleText() {
        XCTAssertEqual(ComposePrompt.visible("<think>planning"), "")
        XCTAssertEqual(ComposePrompt.visible("<think>plan</think>\n\nHello"), "Hello")
        XCTAssertEqual(ComposePrompt.visible("  Hello\n"), "Hello")
        XCTAssertEqual(ComposePrompt.visible("<transcript>\nHello\n</transcript>"), "Hello")
        // A "thinking" build: its template opens the block, so only the closing tag arrives.
        XCTAssertEqual(ComposePrompt.visible("Okay, the user wants me to transform…\nWait, keep \"Hopefully\".\n</think>\n\nThis is a test. Hopefully it works."),
                       "This is a test. Hopefully it works.")
        XCTAssertEqual(ComposePrompt.visible("<think>a</think>draft </think> Final."), "Final.", "the last closing tag wins")
    }
}

final class ComposerTests: XCTestCase {
    func collect(_ stream: AsyncThrowingStream<String, Error>) async throws -> [String] {
        var all: [String] = []
        for try await text in stream { all.append(text) }
        return all
    }

    func testStreamsTheWholeTextSoFar() async throws {
        let client = FakeHTTPClient { _ in
            (200, [#"{"message":{"content":"Hi Sam,"},"done":false}"#,
                   #"{"message":{"content":"\n\nThe launch"},"done":false}"#,
                   #"{"message":{"content":" moves to Friday."},"done":false}"#,
                   #"{"message":{"content":""},"done":true}"#].joined(separator: "\n"))
        }
        let composer = Composer(chat: OllamaChat(model: "qwen3:30b", client: client))
        let updates = try await collect(composer.write("so um tell sam", style: .email, context: CleanupContext(appName: "Mail")))
        XCTAssertEqual(updates, ["Hi Sam,", "Hi Sam,\n\nThe launch", "Hi Sam,\n\nThe launch moves to Friday."])
        let body = jsonBody(try XCTUnwrap(client.requests.first))
        XCTAssertEqual(body["stream"] as? Bool, true)
        XCTAssertEqual(body["think"] as? Bool, false)
        XCTAssertEqual((body["options"] as? [String: Any])?["temperature"] as? Double, 0.3)
        let messages = try XCTUnwrap(body["messages"] as? [[String: String]])
        XCTAssertTrue(messages[0]["content"]?.contains("Format: An email") ?? false)
        XCTAssertTrue(messages[1]["content"]?.hasPrefix("It will be pasted into Mail.") ?? false)
    }

    func testOpenAICompatibleServerSentEvents() async throws {
        let client = FakeHTTPClient { _ in
            (200, [#"data: {"choices":[{"delta":{"role":"assistant"}}]}"#,
                   #"data: {"choices":[{"delta":{"content":"- Milk"}}]}"#,
                   ": keep-alive",
                   #"data: {"choices":[{"delta":{"content":"\n- Eggs"}}]}"#,
                   "data: [DONE]"].joined(separator: "\n"))
        }
        let chat = OpenAICompatibleChat(service: "Groq", baseURL: HostedAPI.groq.baseURL, apiKey: "g", model: "llama", client: client)
        let updates = try await collect(Composer(chat: chat).write("milk eggs", style: .bullets, context: CleanupContext()))
        XCTAssertEqual(updates.last, "- Milk\n- Eggs")
        XCTAssertEqual(jsonBody(try XCTUnwrap(client.requests.first))["stream"] as? Bool, true)
    }

    func testModelsWithoutStreamingGiveOnePiece() async throws {
        let chat = FakeChat { _, _ in "<think>hmm</think>Done." }
        let updates = try await collect(Composer(chat: chat).write("x", style: .auto, context: CleanupContext()))
        XCTAssertEqual(updates, ["Done."])
    }

    func testNothingWrittenIsAnError() async {
        let chat = FakeChat { _, _ in "<think>only thinking</think>  " }
        do {
            _ = try await collect(Composer(chat: chat).write("x", style: .auto, context: CleanupContext()))
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? ComposeError, .empty)
        }
    }

    func testStreamErrorsCarryTheMessage() async {
        let client = FakeHTTPClient { _ in (404, #"{"error":"model \"qwen3:30b\" not found, try pulling it first"}"#) }
        do {
            _ = try await collect(Composer(chat: OllamaChat(model: "qwen3:30b", client: client))
                .write("x", style: .auto, context: CleanupContext()))
            XCTFail("expected an error")
        } catch let error as APIError {
            XCTAssertEqual(error.status, 404)
            XCTAssertTrue(error.message.contains("try pulling it first"))
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    func testOlderOllamaStreamsWithoutTheThinkFlag() async throws {
        let calls = Counter()
        let client = FakeHTTPClient { _ in
            if calls.next() == 1 { return (400, #"{"error":"invalid option: think"}"#) }
            return (200, #"{"message":{"content":"Hi."},"done":true}"#)
        }
        let updates = try await collect(Composer(chat: OllamaChat(model: "qwen3:8b", client: client))
            .write("x", style: .auto, context: CleanupContext()))
        XCTAssertEqual(updates, ["Hi."])
        XCTAssertNil(jsonBody(client.requests[1])["think"])
    }
}

final class ComposeModelChoiceTests: XCTestCase {
    let gb: Int64 = 1_000_000_000
    var local: LocalLLM {
        LocalLLM(server: "Ollama", baseURL: URL(string: "http://127.0.0.1:11434/v1")!,
                 models: ["qwen3:4b", "qwen3:30b", "qwen3-coder:30b", "nomic-embed-text"],
                 sizes: ["qwen3:4b": 2_600_000_000, "qwen3:30b": 18_600_000_000, "qwen3-coder:30b": 18_600_000_000,
                         "nomic-embed-text": 274_000_000])
    }

    func testBiggestGeneralModelThatFits() {
        let gib: UInt64 = 1_073_741_824
        XCTAssertEqual(local.pickModel(for: .compose, memoryBytes: 36 * gib), "qwen3:30b")
        XCTAssertEqual(local.pickModel(for: .compose, memoryBytes: 16 * gib), "qwen3:4b", "a 16 GB Air gets the small one")
        XCTAssertEqual(local.pickModel(preferred: "qwen3:30b", for: .compose, memoryBytes: 8 * gib), "qwen3:30b", "a pinned model wins")
        let onlyBig = LocalLLM(server: "Ollama", baseURL: local.baseURL, models: ["qwen3:30b", "llama3.1:70b"],
                               sizes: ["qwen3:30b": 18_600_000_000, "llama3.1:70b": 40 * gb])
        XCTAssertEqual(onlyBig.pickModel(for: .compose, memoryBytes: 8 * gib), "qwen3:30b", "nothing fits: the smallest")
    }

    func testSuggestionsByMemory() {
        let gib: UInt64 = 1_073_741_824
        XCTAssertEqual(LocalLLM.suggestedComposeModel(memoryBytes: 8 * gib), "qwen3:4b")
        XCTAssertEqual(LocalLLM.suggestedComposeModel(memoryBytes: 16 * gib), "qwen3:8b")
        XCTAssertEqual(LocalLLM.suggestedComposeModel(memoryBytes: 24 * gib), "qwen3:14b")
        XCTAssertEqual(LocalLLM.suggestedComposeModel(memoryBytes: 32 * gib), "qwen3:30b")
        XCTAssertEqual(local.sizeDescription(of: "qwen3:30b"), "18.6 GB")
    }

    func testComposerUsesOllamaAndNeverSkips() throws {
        let composer = try XCTUnwrap(try Config().makeComposer(env: [:], local: local))
        let chat = try XCTUnwrap(composer.chat as? OllamaChat)
        XCTAssertFalse(chat.skipIfNotLoaded, "compose waits for the model to load")
        XCTAssertEqual(composer.timeout, 180)
        XCTAssertNil(try Config().makeComposer(env: [:], local: nil), "nothing to use")
        XCTAssertEqual(try Config().makeComposer(env: ["ANTHROPIC_API_KEY": "a"], local: nil)?.name, "Anthropic claude-haiku-4-5")
    }
}

final class LibraryTests: XCTestCase {
    func entry() -> LibraryEntry {
        LibraryEntry(id: UUID(uuidString: "5D1E4C2A-0000-4000-8000-000000000001")!,
                     created: Date(timeIntervalSince1970: 1_790_000_000), style: .email, app: "Mail",
                     model: "Ollama qwen3:30b",
                     text: "Hi Sam,\n\nThe launch moves to Friday so QA can finish.\n\nThanks",
                     transcript: "so um tell sam the launch moves to friday because QA")
    }

    func testMarkdownRoundTrip() throws {
        let original = entry()
        let text = original.markdown
        XCTAssertTrue(text.hasPrefix("---\nid: 5D1E4C2A-0000-4000-8000-000000000001\ncreated: "))
        XCTAssertTrue(text.contains("style: email\napp: Mail\nmodel: Ollama qwen3:30b\n---\n\nHi Sam,"))
        XCTAssertTrue(text.contains("## What I said\n\nso um tell sam"))
        let parsed = try XCTUnwrap(LibraryEntry.parse(text))
        XCTAssertEqual(parsed, original)
    }

    func testTitles() {
        XCTAssertEqual(entry().title, "Hi Sam,")
        var bullets = entry()
        bullets.text = "## Plan for the offsite in October with the whole team\n- a"
        XCTAssertEqual(bullets.title, "Plan for the offsite in October with the…")
        bullets.text = "Subject: Launch\n\n**Heads up** on dates"
        XCTAssertEqual(bullets.title, "Heads up on dates")
        bullets.text = ""
        XCTAssertEqual(bullets.title, "so um tell sam the launch moves to…", "unwritten: from what was said")
    }

    func testNotALibraryFile() {
        XCTAssertNil(LibraryEntry.parse("# Just notes"))
        XCTAssertNil(LibraryEntry.parse("---\ntitle: x\n---\nbody"))
    }

    func testSaveListUpdateDelete() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("library-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = LibraryStore(folder: folder)
        XCTAssertEqual(store.list(), [])

        var first = try store.save(entry())
        let url = try XCTUnwrap(first.fileURL)
        XCTAssertTrue(url.lastPathComponent.hasSuffix(" Hi Sam,.md"), url.lastPathComponent)
        var second = entry()
        second.id = UUID()
        second.created = first.created.addingTimeInterval(1)
        second = try store.save(second)
        XCTAssertNotEqual(second.fileURL, url, "same title and minute: a second file")

        first.text = "Edited."
        first = try store.save(first)
        XCTAssertEqual(first.fileURL, url, "updates keep their file")
        XCTAssertEqual(store.list().map(\.id), [second.id, first.id], "newest first")
        XCTAssertEqual(store.list().last?.text, "Edited.")

        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try "# Not ours".write(to: folder.appendingPathComponent("notes.md"), atomically: true, encoding: .utf8)
        XCTAssertEqual(store.list().count, 2, "other Markdown files are ignored")

        try store.delete(first)
        XCTAssertEqual(store.list().map(\.id), [second.id])
    }
}

final class ThinkingModelTests: XCTestCase {
    override func setUp() { ThinkingModels.shared.removeAll() }
    override func tearDown() { ThinkingModels.shared.removeAll() }

    func collect(_ stream: AsyncThrowingStream<String, Error>) async throws -> [String] {
        var all: [String] = []
        for try await text in stream { all.append(text) }
        return all
    }

    func testReasoningWithoutAnOpeningTagIsNotInserted() async throws {
        let client = FakeHTTPClient { _ in
            (200, [#"{"message":{"content":"Okay, the user wants"},"done":false}"#,
                   #"{"message":{"content":" a test.\n</think>\n\n"},"done":false}"#,
                   #"{"message":{"content":"This is a test."},"done":false}"#,
                   #"{"message":{"content":""},"done":true}"#].joined(separator: "\n"))
        }
        let chat = OllamaChat(model: "qwen3:30b-thinking-test", client: client)
        let updates = try await collect(Composer(chat: chat).write("x", style: .auto, context: CleanupContext()))
        XCTAssertEqual(updates.last, "This is a test.")
        XCTAssertEqual(jsonBody(client.requests[0])["think"] as? Bool, false)

        // Seen reasoning anyway: next time Ollama is asked to separate it.
        _ = try await collect(Composer(chat: chat).write("x", style: .auto, context: CleanupContext()))
        XCTAssertEqual(jsonBody(client.requests[1])["think"] as? Bool, true)
    }

    func testSeparatedReasoningIsIgnored() async throws {
        ThinkingModels.shared.insert("qwen3:30b-thinking-test")
        let client = FakeHTTPClient { _ in
            (200, [#"{"message":{"thinking":"Okay, the user","content":""},"done":false}"#,
                   #"{"message":{"thinking":" wants a test.","content":""},"done":false}"#,
                   #"{"message":{"content":"This is a test."},"done":false}"#,
                   #"{"message":{"content":""},"done":true}"#].joined(separator: "\n"))
        }
        let chat = OllamaChat(model: "qwen3:30b-thinking-test", client: client)
        let updates = try await collect(Composer(chat: chat).write("x", style: .auto, context: CleanupContext()))
        XCTAssertEqual(updates, ["This is a test."])
    }

    func testCleanupStripsItToo() async throws {
        let client = FakeHTTPClient { _ in (200, #"{"message":{"content":"Reasoning here.\n</think>\nHi there."}}"#) }
        let chat = OllamaChat(model: "qwen3:30b-thinking-test", client: client)
        let reply = try await chat.complete(system: "s", user: "u", maxTokens: 8, timeout: 5)
        XCTAssertEqual(reply, "Hi there.")
        XCTAssertTrue(ThinkingModels.shared.contains("qwen3:30b-thinking-test"))
        XCTAssertFalse(ThinkingModels.shared.contains("qwen3:4b"), "other models keep thinking off")
    }
}
