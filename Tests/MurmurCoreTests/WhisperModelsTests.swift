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

final class CleanupToggleEditTests: XCTestCase {
    func testTogglesTheCleanupFlagOnly() throws {
        let off = try XCTUnwrap(ConfigFileEdit.settingCleanupEnabled(false, in: Config.defaultFileContents))
        let config = try Config.parse(off)
        XCTAssertFalse(config.cleanup.enabled)
        XCTAssertEqual(config.meeting, MeetingConfig(), "nothing else changes")
        XCTAssertTrue(off.contains("// Removes filler words"), "comments survive")
        let on = try XCTUnwrap(ConfigFileEdit.settingCleanupEnabled(true, in: off))
        XCTAssertEqual(on, Config.defaultFileContents)
    }

    func testAddsTheKeyWhenMissing() throws {
        let text = #"{ "cleanup": { "provider": "local" } }"#
        let edited = try XCTUnwrap(ConfigFileEdit.settingCleanupEnabled(false, in: text))
        XCTAssertFalse(try Config.parse(edited).cleanup.enabled)
        XCTAssertEqual(try Config.parse(edited).cleanup.provider, .local)
        XCTAssertNil(ConfigFileEdit.settingCleanupEnabled(false, in: #"{ "hotkey": "fn" }"#))
    }

    func testOnDisk() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        try Config.defaultFileContents.write(to: file, atomically: true, encoding: .utf8)
        XCTAssertTrue(try ConfigFileEdit.setCleanupEnabled(false, in: file))
        XCTAssertFalse(try Config.loadOrCreate(at: file).cleanup.enabled)
        try #"{ "hotkey": "fn" }"#.write(to: file, atomically: true, encoding: .utf8)
        XCTAssertFalse(try ConfigFileEdit.setCleanupEnabled(false, in: file))
    }
}
