import XCTest
@testable import MurmurCore

final class ConfigTests: XCTestCase {
    func testDefaultFileParsesToDefaults() throws {
        XCTAssertEqual(try Config.parse(Config.defaultFileContents), Config())
    }

    func testMissingKeysKeepDefaults() throws {
        let config = try Config.parse(#"{ "hotkey": "rightOption", "insertion": { "restoreClipboard": true } }"#)
        XCTAssertEqual(config.hotkey, "rightOption")
        XCTAssertTrue(config.insertion.restoreClipboard)
        XCTAssertEqual(config.insertion.method, .paste)
        XCTAssertEqual(config.transcription, TranscriptionConfig())
    }

    func testEmptyFileIsDefaults() throws {
        XCTAssertEqual(try Config.parse("  // nothing here\n"), Config())
    }

    func testCommentsAndTrailingCommas() throws {
        let text = """
        {
          /* block */ "hotkey": "ctrl+option+space", // line comment
          "transcription": { "engine": "local", "vocabulary": ["Kubernetes", "http://x//y",], },
        }
        """
        let config = try Config.parse(text)
        XCTAssertEqual(config.hotkey, "ctrl+option+space")
        XCTAssertEqual(config.transcription.engine, .local)
        XCTAssertEqual(config.transcription.vocabulary, ["Kubernetes", "http://x//y"])
    }

    func testStripKeepsEscapedQuotesInStrings() {
        XCTAssertEqual(JSONC.strip(#"{"a": "say \"//hi\"", } // x"#), #"{"a": "say \"//hi\"" } "#)
    }

    func testUnknownEngineIsAnError() {
        XCTAssertThrowsError(try Config.parse(#"{ "transcription": { "engine": "cloud" } }"#))
    }

    func testLoadOrCreateWritesDefaultFile() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("config.json")
        XCTAssertEqual(try Config.loadOrCreate(at: url), Config())
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), Config.defaultFileContents)
    }

    func testExpandTilde() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        XCTAssertEqual(AppPaths.expandTilde("~/x/y"), home + "/x/y")
        XCTAssertEqual(AppPaths.expandTilde("/abs"), "/abs")
        XCTAssertEqual(AppPaths.expandTilde("~other/x"), "~other/x")
    }
}

final class DotEnvTests: XCTestCase {
    func testParse() {
        let env = DotEnv.parse("""
        # comment
        GROQ_API_KEY=gsk_123
        export OPENAI_API_KEY = "sk-abc # not a comment"
        ANTHROPIC_API_KEY='sk-ant'
        EMPTY=
        TRAILING=value # comment
        not a line
        """)
        XCTAssertEqual(env["GROQ_API_KEY"], "gsk_123")
        XCTAssertEqual(env["OPENAI_API_KEY"], "sk-abc # not a comment")
        XCTAssertEqual(env["ANTHROPIC_API_KEY"], "sk-ant")
        XCTAssertEqual(env["EMPTY"], "")
        XCTAssertEqual(env["TRAILING"], "value")
        XCTAssertEqual(env.count, 5)
    }

    func testFileOverridesEnvironment() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).env")
        defer { try? FileManager.default.removeItem(at: url) }
        try "A=file\n".write(to: url, atomically: true, encoding: .utf8)
        let env = DotEnv.load(from: url, environment: ["A": "process", "B": "process"])
        XCTAssertEqual(env, ["A": "file", "B": "process"])
    }
}

final class HotkeySpecTests: XCTestCase {
    func testModifierOnly() throws {
        XCTAssertEqual(try HotkeySpec.parse("fn"), .modifier(.fn))
        XCTAssertEqual(try HotkeySpec.parse("Globe"), .modifier(.fn))
        XCTAssertEqual(try HotkeySpec.parse("rightOption"), .modifier(.rightOption))
        XCTAssertEqual(try HotkeySpec.parse("right_cmd"), .modifier(.rightCommand))
        XCTAssertTrue(try HotkeySpec.parse("lshift").isModifierOnly)
    }

    func testShortcut() throws {
        let spec = try HotkeySpec.parse("ctrl+option+space")
        XCTAssertEqual(spec, .shortcut(keyCode: 49, modifiers: [.control, .option], display: "⌃⌥Space"))
        XCTAssertFalse(spec.isModifierOnly)
        XCTAssertEqual(try HotkeySpec.parse("cmd + shift + d").displayName, "⇧⌘D")
        XCTAssertEqual(try HotkeySpec.parse("F13"), .shortcut(keyCode: 105, modifiers: [], display: "F13"))
    }

    func testErrors() {
        XCTAssertThrowsError(try HotkeySpec.parse("")) { XCTAssertEqual($0 as? HotkeySpec.ParseError, .empty) }
        XCTAssertThrowsError(try HotkeySpec.parse("ctrl+banana")) { XCTAssertEqual($0 as? HotkeySpec.ParseError, .unknownKey("banana")) }
        XCTAssertThrowsError(try HotkeySpec.parse("esc")) { XCTAssertEqual($0 as? HotkeySpec.ParseError, .escapeNotAllowed) }
        XCTAssertThrowsError(try HotkeySpec.parse("ctrl+option")) { XCTAssertEqual($0 as? HotkeySpec.ParseError, .noKey("ctrl+option")) }
        XCTAssertThrowsError(try HotkeySpec.parse("a+b"))
    }

    func testFlags() {
        XCTAssertTrue(ModifierKey.fn.isDown(flags: 0x0080_0100))
        XCTAssertFalse(ModifierKey.fn.isDown(flags: 0x0000_0100))
        // Left option held (0x20 plus the generic alternate flag), right option not.
        XCTAssertTrue(ModifierKey.leftOption.isDown(flags: 0x0008_0120))
        XCTAssertFalse(ModifierKey.rightOption.isDown(flags: 0x0008_0120))
        XCTAssertEqual(ShortcutModifiers(eventFlags: 0x0094_0000), [.control, .command])
    }
}
