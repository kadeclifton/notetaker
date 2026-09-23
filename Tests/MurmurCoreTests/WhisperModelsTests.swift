import XCTest
@testable import MurmurCore

final class WhisperModelsTests: XCTestCase {
    func testCatalog() {
        XCTAssertEqual(WhisperModelOption.catalog.map(\.id), ["base.en", "small.en", "large-v3-turbo-q5_0"])
        XCTAssertEqual(WhisperModelOption.small.configPath, "models/ggml-small.en.bin")
        XCTAssertEqual(WhisperModelOption.turbo.url.absoluteString,
                       "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo-q5_0.bin")
        XCTAssertEqual(WhisperModelOption.matching(path: "~/.config/murmur/models/ggml-base.en.bin"), .base)
        XCTAssertNil(WhisperModelOption.matching(path: "/custom/ggml-medium.bin"))
        XCTAssertEqual(WhisperModelOption.matching(path: WhisperCppConfig().model), .small, "the default is in the catalog")
    }

    func testEditKeepsCommentsAndTheCleanupModel() throws {
        let edited = try XCTUnwrap(ConfigFileEdit.settingWhisperModel(WhisperModelOption.turbo.configPath,
                                                                       in: Config.defaultFileContents))
        let config = try Config.parse(edited)
        XCTAssertEqual(config.transcription.whisperCpp.model, "models/ggml-large-v3-turbo-q5_0.bin")
        XCTAssertEqual(config.cleanup.model, "")
        XCTAssertTrue(edited.contains("// Murmur settings."), "comments survive")
        XCTAssertEqual(edited.count - Config.defaultFileContents.count,
                       "models/ggml-large-v3-turbo-q5_0.bin".count - "models/ggml-small.en.bin".count)
    }

    func testEditHandlesAbsolutePathsAndMissingLines() {
        let text = #"{ "transcription": { "whisperCpp": { "model" : "/Users/me/ggml-medium.en.bin" } }, "cleanup": { "model": "qwen3:4b" } }"#
        XCTAssertEqual(ConfigFileEdit.settingWhisperModel("models/ggml-base.en.bin", in: text),
                       #"{ "transcription": { "whisperCpp": { "model" : "models/ggml-base.en.bin" } }, "cleanup": { "model": "qwen3:4b" } }"#)
        XCTAssertNil(ConfigFileEdit.settingWhisperModel("x.bin", in: #"{ "hotkey": "fn" }"#))
    }

    func testEditOnDisk() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        try Config.defaultFileContents.write(to: file, atomically: true, encoding: .utf8)
        XCTAssertTrue(try ConfigFileEdit.setWhisperModel(WhisperModelOption.base.configPath, in: file))
        XCTAssertEqual(try Config.loadOrCreate(at: file).transcription.whisperCpp.model, "models/ggml-base.en.bin")
    }
}

final class ConfigFileEditTests: XCTestCase {
    func testChangesOneValueAndKeepsComments() throws {
        let edited = try XCTUnwrap(ConfigFileEdit.setting("modes", "hotkey", json: ConfigFileEdit.quoted("clean"),
                                                          in: Config.defaultFileContents) { $0.modes.hotkey == .clean })
        let config = try Config.parse(edited)
        XCTAssertEqual(config.modes.hotkey, .clean)
        XCTAssertEqual(config.modes.withControlOption, .compose)
        XCTAssertEqual(config.hotkey, "fn", "the top-level hotkey is untouched")
        XCTAssertTrue(edited.contains("// What each way of holding the hotkey does"), "comments survive")
        let back = try XCTUnwrap(ConfigFileEdit.setting("modes", "hotkey", json: #""dictate""#, in: edited) { _ in true })
        XCTAssertEqual(back, Config.defaultFileContents)
    }

    func testBooleansAndStrings() throws {
        let off = try XCTUnwrap(ConfigFileEdit.setting("cleanup", "enabled", json: "false",
                                                       in: Config.defaultFileContents) { !$0.cleanup.enabled })
        XCTAssertEqual(try Config.parse(off).meeting, MeetingConfig(), "nothing else changes")
        let model = try XCTUnwrap(ConfigFileEdit.setting("compose", "model", json: ConfigFileEdit.quoted("qwen3:30b"),
                                                         in: off) { $0.compose.model == "qwen3:30b" })
        XCTAssertEqual(try Config.parse(model).cleanup.model, "", "only compose.model changed")
        XCTAssertFalse(try Config.parse(model).cleanup.enabled)
    }

    func testAddsAMissingKey() throws {
        let text = #"{ "cleanup": { "provider": "local" } }"#
        let edited = try XCTUnwrap(ConfigFileEdit.setting("cleanup", "enabled", json: "false", in: text) { !$0.cleanup.enabled })
        XCTAssertEqual(try Config.parse(edited).cleanup.provider, .local)
    }

    func testAddsAMissingSectionToAnOlderFile() throws {
        for text in ["{\n  \"hotkey\": \"fn\"\n}\n", "{\n  \"hotkey\": \"fn\",\n  // done\n}\n", "{}"] {
            let edited = try XCTUnwrap(ConfigFileEdit.setting("modes", "hotkey", json: #""clean""#, in: text) { $0.modes.hotkey == .clean },
                                       "for \(text)")
            XCTAssertEqual(try Config.parse(edited).hotkey, "fn")
        }
    }

    func testRefusesWhatWouldNotVerify() {
        XCTAssertNil(ConfigFileEdit.setting("modes", "hotkey", json: #""shout""#, in: Config.defaultFileContents) { _ in true })
        XCTAssertNil(ConfigFileEdit.setting("modes", "hotkey", json: #""clean""#, in: "not json") { _ in true })
    }

    func testQuoting() {
        XCTAssertEqual(ConfigFileEdit.quoted(#"say "hi""#), #""say \"hi\"""#)
    }

    func testOnDisk() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        try Config.defaultFileContents.write(to: file, atomically: true, encoding: .utf8)
        XCTAssertTrue(try ConfigFileEdit.set("cleanup", "enabled", json: "false", in: file) { !$0.cleanup.enabled })
        XCTAssertFalse(try Config.loadOrCreate(at: file).cleanup.enabled)
    }
}
