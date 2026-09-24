import XCTest
@testable import MurmurCore

final class VoiceCommandsTests: XCTestCase {
    func testSnippetMatchesWholeUtteranceIgnoringCaseAndPunctuation() {
        let snippets = [Snippet(say: "my address", insert: "1 Infinite Loop\nCupertino")]
        XCTAssertEqual(VoiceCommands.snippet(for: " My address. ", in: snippets), "1 Infinite Loop\nCupertino")
        XCTAssertEqual(VoiceCommands.snippet(for: "My, address!", in: snippets), "1 Infinite Loop\nCupertino")
        XCTAssertNil(VoiceCommands.snippet(for: "Send it to my address.", in: snippets))
        XCTAssertNil(VoiceCommands.snippet(for: "", in: [Snippet(say: "", insert: "x")]))
    }

    func testUndoAndScratch() {
        XCTAssertTrue(VoiceCommands.isUndo("Scratch that."))
        XCTAssertTrue(VoiceCommands.isUndo("undo that"))
        XCTAssertFalse(VoiceCommands.isUndo("Please scratch that idea from the list."))
        XCTAssertTrue(VoiceCommands.isScratched("Let's meet at three, no, scratch that."))
        XCTAssertFalse(VoiceCommands.isScratched("Let's scratch that itch."))
        XCTAssertFalse(VoiceCommands.isScratched("I wrote scratchthat"))
    }

    func testHotkeyConfigNamesRoundTrip() throws {
        XCTAssertEqual(HotkeySpec.configName(keyCode: 61, modifiers: [], modifierOnly: true), "rightOption")
        XCTAssertEqual(HotkeySpec.configName(keyCode: 63, modifiers: [], modifierOnly: true), "fn")
        let name = try XCTUnwrap(HotkeySpec.configName(keyCode: 49, modifiers: [.control, .option], modifierOnly: false))
        XCTAssertEqual(name, "ctrl+option+space")
        XCTAssertEqual(try HotkeySpec.parse(name), .shortcut(keyCode: 49, modifiers: [.control, .option], display: "⌃⌥Space"))
        XCTAssertEqual(HotkeySpec.configName(keyCode: 36, modifiers: [.command], modifierOnly: false), "cmd+return")
        XCTAssertEqual(HotkeySpec.configName(keyCode: 105, modifiers: [], modifierOnly: false), "f13")
        XCTAssertNil(HotkeySpec.configName(keyCode: 53, modifiers: [.control], modifierOnly: false), "Esc cancels")
        XCTAssertNil(HotkeySpec.configName(keyCode: 0, modifiers: [], modifierOnly: false), "a bare letter")
        for code in HotkeySpec.keyNames.keys where code != 53 {
            let name = try XCTUnwrap(HotkeySpec.configName(keyCode: code, modifiers: [.command], modifierOnly: false))
            guard case let .shortcut(parsed, _, _) = try HotkeySpec.parse(name) else { return XCTFail(name) }
            XCTAssertEqual(parsed, code, name)
        }
    }
}

final class ConfigTextTests: XCTestCase {
    func testReplacesTopLevelHotkeyNotTheModesOne() throws {
        let text = Config.defaultFileContents
        let edited = try XCTUnwrap(ConfigFileEdit.settingTopLevel("hotkey", json: "\"rightOption\"", in: text) { $0.hotkey == "rightOption" })
        let config = try Config.parse(edited)
        XCTAssertEqual(config.hotkey, "rightOption")
        XCTAssertEqual(config.modes.hotkey, .dictate)
        XCTAssertTrue(edited.contains("// Hold to talk"), "comments are kept")
    }

    func testAddsAMissingKeyAndReplacesArrays() throws {
        let text = "{\n  // mine\n  \"hotkey\": \"fn\"\n}\n"
        let snippets = [Snippet(say: "sig", insert: "Best,\n\"Kade\" / home")]
        let json = ConfigFileEdit.json(snippets)
        let added = try XCTUnwrap(ConfigFileEdit.settingTopLevel("snippets", json: json, in: text) { $0.snippets == snippets })
        XCTAssertTrue(added.contains("// mine"))
        let emptied = try XCTUnwrap(ConfigFileEdit.settingTopLevel("snippets", json: "[]", in: added) { $0.snippets.isEmpty })
        XCTAssertEqual(try Config.parse(emptied).hotkey, "fn")
        XCTAssertNil(ConfigText.topLevelValue("say", in: added), "nested keys are not top-level")
    }

    func testIgnoresKeysInsideCommentsAndStrings() {
        let text = "{ /* \"hotkey\": 1 */ \"a\": \"\\\"hotkey\\\": 2\", // \"hotkey\": 3\n \"hotkey\": \"f13\" }"
        let range = ConfigText.topLevelValue("hotkey", in: text)
        XCTAssertEqual(range.map { String(text[$0]) }, "\"f13\"")
    }

    func testDefaultFileHasTheNewSettings() throws {
        XCTAssertEqual(try Config.parse(Config.defaultFileContents), Config())
        XCTAssertTrue(Config().meeting.offerWhenCallStarts)
    }
}

final class MeetingFilesTests: XCTestCase {
    func testParsesMeetingNotes() throws {
        var transcript = MeetingTranscript()
        transcript.add(MeetingSegment(start: 3, speaker: .me, text: "Ship it Friday."))
        let text = MeetingNotes.markdown(title: "Meeting, Sep 23", details: "Zoom", summary: "- Ship Friday", transcript: transcript)
        let url = URL(fileURLWithPath: "/tmp/2026-09-23 1530 Meeting.md")
        let file = try XCTUnwrap(MeetingFile.parse(text, url: url, fallbackDate: Date(timeIntervalSince1970: 0)))
        XCTAssertEqual(file.title, "Meeting, Sep 23")
        XCTAssertEqual(file.summary, "- Ship Friday")
        XCTAssertTrue(file.matches("friday"))
        XCTAssertFalse(file.matches("banana"))
        let c = Calendar.current.dateComponents([.year, .hour, .minute], from: file.date)
        XCTAssertEqual([c.year, c.hour, c.minute], [2026, 15, 30])

        let running = MeetingNotes.markdown(title: "T", details: "", summary: nil, transcript: transcript)
        XCTAssertEqual(MeetingFile.parse(running, url: url, fallbackDate: Date())?.summary, "")
        XCTAssertNil(MeetingFile.parse("---\nid: x\n---\nhello", url: url, fallbackDate: Date()))
    }

    func testStoreListsNewestFirst() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        for name in ["2026-09-01 0900 Meeting.md", "2026-09-20 1000 Meeting.md"] {
            let text = MeetingNotes.markdown(title: name, details: "", summary: nil, transcript: MeetingTranscript())
            try Data(text.utf8).write(to: folder.appendingPathComponent(name))
        }
        try Data("not a meeting".utf8).write(to: folder.appendingPathComponent("notes.md"))
        XCTAssertEqual(MeetingStore(folder: folder).list().map(\.title), ["2026-09-20 1000 Meeting.md", "2026-09-01 0900 Meeting.md"])
    }
}

final class CallDetectorTests: XCTestCase {
    func testOffersOncePerCallAfterSettling() {
        var detector = CallDetector(settle: 5)
        let t0 = Date(timeIntervalSince1970: 1000)
        XCTAssertNil(detector.update(micBusy: true, runningApps: ["us.zoom.xos"], murmurRecording: false, now: t0))
        XCTAssertEqual(detector.update(micBusy: true, runningApps: ["us.zoom.xos"], murmurRecording: false, now: t0 + 6), "Zoom")
        XCTAssertNil(detector.update(micBusy: true, runningApps: ["us.zoom.xos"], murmurRecording: false, now: t0 + 20))
        XCTAssertNil(detector.update(micBusy: false, runningApps: ["us.zoom.xos"], murmurRecording: false, now: t0 + 30))
        XCTAssertNil(detector.update(micBusy: true, runningApps: ["us.zoom.xos"], murmurRecording: false, now: t0 + 40))
        XCTAssertEqual(detector.update(micBusy: true, runningApps: ["us.zoom.xos"], murmurRecording: false, now: t0 + 46), "Zoom")
    }

    func testNoOfferWithoutMeetingAppOrWhileMurmurRecords() {
        var detector = CallDetector(settle: 0)
        let now = Date()
        XCTAssertNil(detector.update(micBusy: true, runningApps: ["com.apple.VoiceMemos"], murmurRecording: false, now: now))
        var recording = CallDetector(settle: 0)
        XCTAssertNil(recording.update(micBusy: true, runningApps: ["us.zoom.xos"], murmurRecording: true, now: now))
        XCTAssertNil(recording.update(micBusy: true, runningApps: ["us.zoom.xos"], murmurRecording: false, now: now + 10))
    }
}

final class DiagnosticsTests: XCTestCase {
    func testAlignsAndRedactsHome() {
        var d = Diagnostics()
        d.add("Version", "0.1.8")
        d.add("Model", NSHomeDirectory() + "/.config/murmur/models/ggml-small.en.bin")
        d.add("Last error", nil)
        XCTAssertEqual(d.text, """
        Murmur diagnostics
        Version:    0.1.8
        Model:      ~/.config/murmur/models/ggml-small.en.bin
        Last error: —

        """)
    }
}
