#if os(macOS)
import AppKit
import SwiftUI
import MurmurCore

/// The settings people change most, without editing the settings file.
@MainActor
final class SettingsWindowController {
    let model: SettingsModel
    private var window: NSWindow?

    init(controller: DictationController) {
        model = SettingsModel(controller: controller)
    }

    func show(tab: SettingsTab? = nil) {
        if let tab { model.tab = tab }
        model.refresh()
        if window == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 460),
                                  styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
            window.title = "Murmur Settings"
            window.contentView = NSHostingView(rootView: SettingsView(model: model))
            window.isReleasedWhenClosed = false
            window.center()
            self.window = window
            NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.model.cancelHotkeyRecording() }
            }
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    /// Something changed (settings reloaded, a download finished): redraw if open.
    func refresh() {
        guard window?.isVisible == true else { return }
        model.refresh()
    }
}

/// A snippet row with an identity that survives typing in it.
struct SnippetDraft: Identifiable, Equatable {
    let id = UUID()
    var say: String
    var insert: String

    init(_ snippet: Snippet) {
        say = snippet.say
        insert = snippet.insert
    }

    var snippet: Snippet { Snippet(say: say, insert: insert) }
}

enum SettingsTab: String, CaseIterable {
    case general = "General"
    case speech = "Speech"
    case writing = "Writing"
    case snippets = "Snippets"
    case meetings = "Meetings"
    case about = "About"

    var symbol: String {
        switch self {
        case .general: return "gearshape"
        case .speech: return "mic"
        case .writing: return "sparkles"
        case .snippets: return "text.badge.plus"
        case .meetings: return "person.2.wave.2"
        case .about: return "info.circle"
        }
    }
}

@MainActor
final class SettingsModel: ObservableObject {
    let controller: DictationController
    @Published var tab: SettingsTab = .general
    /// Bumped to redraw from the controller's state.
    @Published private(set) var revision = 0
    /// Snippets as edited in the window; saved with Save.
    @Published var snippets: [SnippetDraft] = []
    /// What the settings file had when `snippets` was last loaded.
    private var loadedSnippets: [Snippet] = []
    var snippetsChanged: Bool { snippets.map(\.snippet) != loadedSnippets }
    @Published private(set) var recordingHotkey = false
    @Published private(set) var hotkeyMessage: String?
    private var monitor: Any?
    private var pendingModifier: UInt16?
    private var sawKeyWithModifier = false

    init(controller: DictationController) {
        self.controller = controller
    }

    func refresh() {
        // Unsaved edits are kept; otherwise show what the settings file says now.
        if !snippetsChanged, loadedSnippets != controller.snippets {
            loadedSnippets = controller.snippets
            snippets = loadedSnippets.map(SnippetDraft.init)
        }
        revision += 1
    }

    // MARK: Snippets

    func saveSnippets() {
        controller.setSnippets(snippets.map(\.snippet))
        loadedSnippets = controller.snippets
        snippets = loadedSnippets.map(SnippetDraft.init)
    }

    func removeSnippet(_ id: UUID) {
        snippets.removeAll { $0.id == id }
        saveSnippets()
    }

    // MARK: Hotkey picker

    func startHotkeyRecording() {
        guard !recordingHotkey else { return }
        recordingHotkey = true
        hotkeyMessage = "Press the key (or shortcut) to use. Esc cancels."
        pendingModifier = nil
        sawKeyWithModifier = false
        controller.pauseHotkey()
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            // Local monitors run on the main thread. Every key goes to the picker, not the window.
            let type = event.type
            let keyCode = event.keyCode
            let flags = UInt64(event.modifierFlags.rawValue)
            MainActor.assumeIsolated { self?.handle(type: type, keyCode: keyCode, flags: flags) }
            return nil
        }
    }

    func cancelHotkeyRecording() {
        guard recordingHotkey else { return }
        finishRecording()
        hotkeyMessage = nil
        controller.resumeHotkey()
    }

    private func finishRecording() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        recordingHotkey = false
    }

    /// A modifier pressed and released alone picks that modifier; any key pressed picks a shortcut.
    private func handle(type: NSEvent.EventType, keyCode: UInt16, flags: UInt64) {
        guard recordingHotkey else { return }
        if type == .keyDown {
            if keyCode == 53 {
                cancelHotkeyRecording()
                return
            }
            pendingModifier = nil
            sawKeyWithModifier = true
            let modifiers = ShortcutModifiers(eventFlags: flags)
            guard let name = HotkeySpec.configName(keyCode: Int64(keyCode), modifiers: modifiers, modifierOnly: false) else {
                hotkeyMessage = "That key can't be the hotkey. Add ⌃, ⌥ or ⌘, or pick a modifier or F-key."
                return
            }
            choose(name)
            return
        }
        // flagsChanged: which modifier moved, and is it now down?
        guard let key = ModifierKey.allCases.first(where: { $0.keyCode == Int64(keyCode) }) else { return }
        if key.isDown(flags: flags) {
            pendingModifier = keyCode
            sawKeyWithModifier = false
        } else if pendingModifier == keyCode, !sawKeyWithModifier,
                  let name = HotkeySpec.configName(keyCode: Int64(keyCode), modifiers: [], modifierOnly: true) {
            choose(name)
        }
    }

    private func choose(_ name: String) {
        finishRecording()
        hotkeyMessage = nil
        controller.setHotkey(name)
        refresh()
    }
}

private struct SettingsView: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        TabView(selection: $model.tab) {
            GeneralTab(model: model).tabItem { Label("General", systemImage: SettingsTab.general.symbol) }.tag(SettingsTab.general)
            SpeechTab(model: model).tabItem { Label("Speech", systemImage: SettingsTab.speech.symbol) }.tag(SettingsTab.speech)
            WritingTab(model: model).tabItem { Label("Writing", systemImage: SettingsTab.writing.symbol) }.tag(SettingsTab.writing)
            SnippetsTab(model: model).tabItem { Label("Snippets", systemImage: SettingsTab.snippets.symbol) }.tag(SettingsTab.snippets)
            MeetingsTab(model: model).tabItem { Label("Meetings", systemImage: SettingsTab.meetings.symbol) }.tag(SettingsTab.meetings)
            AboutTab(model: model).tabItem { Label("About", systemImage: SettingsTab.about.symbol) }.tag(SettingsTab.about)
        }
        .padding(20)
        .frame(width: 560, height: 460)
    }
}

// MARK: - Tabs

private struct GeneralTab: View {
    @ObservedObject var model: SettingsModel
    private var c: DictationController { model.controller }

    var body: some View {
        Form {
            Section {
                LabeledContent("Hotkey") {
                    HStack {
                        Text(model.recordingHotkey ? "Press a key…" : c.hotkeyDescription)
                            .font(.system(.body, design: .rounded).weight(.semibold))
                            .padding(.horizontal, 10).padding(.vertical, 3)
                            .background(RoundedRectangle(cornerRadius: 6)
                                .fill(model.recordingHotkey ? Color.accentColor.opacity(0.25) : Color.purple.opacity(0.12)))
                        if model.recordingHotkey {
                            Button("Cancel") { model.cancelHotkeyRecording() }
                        } else {
                            Button("Change…") { model.startHotkeyRecording() }
                            if c.hotkeySetting != "fn" { Button("Use fn") { c.setHotkey("fn") } }
                        }
                    }
                }
                if let message = model.hotkeyMessage {
                    Text(message).font(.caption).foregroundStyle(.secondary)
                } else {
                    Text(c.hasModes
                         ? "Hold to talk, double-tap for hands-free. Add ⌃ to clean up, ⌃⌥ to compose."
                         : "A shortcut hotkey dictates only; pick a single modifier like fn or right ⌥ to get clean-up and compose too.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if c.hasModes {
                    Toggle("Clean up plain \(c.hotkeyDescription) too", isOn: Binding(
                        get: { c.plainMode == .clean },
                        set: { c.setPlainMode($0 ? .clean : .dictate) }))
                        .disabled(![.dictate, .clean].contains(c.plainMode))
                }
            }
            Section {
                Toggle("Dictation on", isOn: Binding(get: { c.enabled }, set: { c.enabled = $0 }))
                Toggle("Launch at login", isOn: Binding(get: { LoginItem.isEnabled }, set: { on in _ = try? LoginItem.set(on) }))
                Toggle("Sounds", isOn: Binding(get: { c.config.feedback.sounds }, set: { on in
                    c.editSettings("feedback", "sounds", json: on ? "true" : "false") { $0.feedback.sounds == on }
                }))
                Toggle("Show the pill while recording", isOn: Binding(get: { c.config.feedback.pill }, set: { on in
                    c.editSettings("feedback", "pill", json: on ? "true" : "false") { $0.feedback.pill == on }
                }))
                Picker("Pill position", selection: Binding(get: { c.pillPosition }, set: { c.pillPosition = $0 })) {
                    ForEach(PillPosition.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .disabled(!c.config.feedback.pill)
            }
        }
        .formStyle(.grouped)
    }
}

private struct SpeechTab: View {
    @ObservedObject var model: SettingsModel
    @State private var newWord = ""
    private var c: DictationController { model.controller }

    var body: some View {
        Form {
            Section {
                Picker("Microphone", selection: Binding(get: { c.microphoneUID ?? "" }, set: { c.setMicrophone($0.isEmpty ? nil : $0) })) {
                    Text("System Default" + (c.defaultMicrophoneName.map { " (\($0))" } ?? "")).tag("")
                    ForEach(c.microphones, id: \.uid) { Text($0.name).tag($0.uid) }
                }
                if c.usesLocalWhisper {
                    Picker("Speech model", selection: Binding(
                        get: { c.currentWhisperModel?.id ?? "" },
                        set: { id in if let option = WhisperModelOption.catalog.first(where: { $0.id == id }) { c.selectWhisperModel(option) } })) {
                        if c.currentWhisperModel == nil { Text("Custom").tag("") }
                        ForEach(WhisperModelOption.catalog, id: \.id) { option in
                            let installed = FileManager.default.fileExists(atPath: option.localURL().path)
                            Text(option.title + (installed ? "" : " · \(option.megabytes) MB download")).tag(option.id)
                        }
                    }
                    .disabled(c.downloader.isDownloading)
                    if case let .downloading(option, progress) = c.downloader.state {
                        ProgressView("Downloading \(option.title)…", value: progress)
                    }
                    NeuralEngineRow(controller: c, installer: c.coreML)
                }
                LabeledContent("Transcription", value: c.transcriberName)
                if let timing = c.lastTiming { LabeledContent("Last dictation", value: timing) }
            }
            Section("Vocabulary") {
                Text("Names and jargon Whisper keeps getting wrong, spelled the way they should appear.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    TextField("Add a word", text: $newWord).onSubmit(add)
                    Button("Add", action: add).disabled(newWord.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                ForEach(c.vocabulary, id: \.self) { word in
                    HStack {
                        Text(word)
                        Spacer()
                        Button { c.removeVocabulary(word) } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private func add() {
        c.addVocabulary(newWord)
        newWord = ""
    }
}

/// Cleanup (hotkey + ⌃) and Compose (hotkey + ⌃⌥): which models, and how long they stay loaded.
private struct WritingTab: View {
    @ObservedObject var model: SettingsModel
    private var c: DictationController { model.controller }

    var body: some View {
        Form {
            Section("Clean up") {
                LabeledContent("Model", value: c.cleanerName)
                if c.hasModes {
                    Toggle("Clean up plain \(c.hotkeyDescription) too", isOn: Binding(
                        get: { c.plainMode == .clean },
                        set: { c.setPlainMode($0 ? .clean : .dictate) }))
                        .disabled(![.dictate, .clean].contains(c.plainMode))
                }
                if let ollama = c.cleanupOllamaModel {
                    Picker("Keep \(ollama) loaded", selection: Binding(get: { c.keepAlive }, set: { c.keepAlive = $0 })) {
                        ForEach(KeepAlive.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                }
            }
            Section("Compose") {
                LabeledContent("Model", value: c.composerName)
                let choices = c.composeModelChoices
                if !choices.isEmpty {
                    Picker("Compose model", selection: Binding(get: { c.composeModelSetting }, set: { c.setComposeModel($0) })) {
                        Text("Automatic" + (c.automaticComposeModel.map { " (\($0))" } ?? "")).tag("")
                        ForEach(choices, id: \.self) { name in
                            Text(name + (c.composeModelSize(name).map { " · \($0)" } ?? "")).tag(name)
                        }
                    }
                    Text("Automatic picks the best one that fits this Mac. Pick a smaller one if writing feels slow.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let suggestion = c.composeSuggestion {
                    HStack {
                        Text("Better for this Mac: \(suggestion)").font(.callout)
                        Spacer()
                        Button("Copy \"ollama pull\"") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString("ollama pull \(suggestion)", forType: .string)
                        }
                    }
                }
            }
            Section {
                LabeledContent("Meeting summaries", value: c.summaryName)
                Button("Look for Ollama or LM Studio Again") { c.detectLocalLLM() }
            }
        }
        .formStyle(.grouped)
    }
}

/// Core ML on or off for the current speech model.
private struct NeuralEngineRow: View {
    let controller: DictationController
    @ObservedObject var installer: CoreMLInstaller

    var body: some View {
        if controller.neuralEngineAvailable, let option = controller.currentWhisperModel {
            Toggle(isOn: Binding(get: { controller.neuralEngineOn || installer.isBusy },
                                 set: { controller.setNeuralEngine($0) })) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Use the Neural Engine")
                    Text(controller.neuralEngineOn
                         ? "The speech encoder runs on the Neural Engine, leaving the GPU free."
                         : "Runs the speech encoder on Apple's Neural Engine: less GPU and battery. A \(option.coreMLMegabytes) MB download; the first load takes a minute or two.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            switch installer.state {
            case let .downloading(progress):
                ProgressView("Downloading the Core ML encoder…", value: progress)
            case .unpacking:
                ProgressView("Unpacking…")
            case let .failed(message):
                Text(message).font(.caption).foregroundStyle(.red)
            case .idle:
                EmptyView()
            }
        }
    }
}

private struct SnippetsTab: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Say the phrase on its own, and the text is inserted instead. Say \u{201C}scratch that\u{201D} on its own to undo the last dictation.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if model.snippets.isEmpty {
                Text("No snippets yet. Try \u{201C}my email\u{201D} → your address, or \u{201C}sign off\u{201D} → your signature.")
                    .font(.callout).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 80)
            }
            ScrollView {
                VStack(spacing: 8) {
                    ForEach($model.snippets) { $draft in
                        HStack(alignment: .top) {
                            TextField("When I say…", text: $draft.say)
                                .frame(width: 150)
                            TextEditor(text: $draft.insert)
                                .font(.body)
                                .frame(height: 54)
                                .scrollContentBackground(.hidden)
                                .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.05)))
                            Button { model.removeSnippet(draft.id) } label: { Image(systemName: "minus.circle") }
                                .buttonStyle(.borderless)
                        }
                    }
                }
            }
            HStack {
                Button("Add Snippet") { model.snippets.append(SnippetDraft(Snippet(say: "", insert: ""))) }
                Spacer()
                if model.snippetsChanged { Text("Not saved yet").font(.caption).foregroundStyle(.secondary) }
                Button("Save") { model.saveSnippets() }
                    .keyboardShortcut("s")
                    .disabled(!model.snippetsChanged)
            }
        }
    }
}

private struct MeetingsTab: View {
    @ObservedObject var model: SettingsModel
    private var c: DictationController { model.controller }

    var body: some View {
        Form {
            Section {
                Toggle("Offer to take notes when a call starts", isOn: Binding(get: { c.config.meeting.offerWhenCallStarts }, set: { on in
                    c.editSettings("meeting", "offerWhenCallStarts", json: on ? "true" : "false") { $0.meeting.offerWhenCallStarts == on }
                }))
                Text("When Zoom, Teams, FaceTime, Slack or a browser starts using the microphone, Murmur asks. It never records without you saying yes.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Record the call's audio, not just my mic", isOn: Binding(get: { c.config.meeting.captureSystemAudio }, set: { on in
                    c.editSettings("meeting", "captureSystemAudio", json: on ? "true" : "false") { $0.meeting.captureSystemAudio == on }
                }))
                Toggle("Write a summary when it ends", isOn: Binding(get: { c.config.meeting.summarize }, set: { on in
                    c.editSettings("meeting", "summarize", json: on ? "true" : "false") { $0.meeting.summarize == on }
                }))
                LabeledContent("Summaries by", value: c.summaryName)
            }
            Section {
                HStack {
                    Button("Meetings in Library…") { c.showLibrary(section: .meetings) }
                    Button("Open Folder") { c.openMeetingsFolder() }
                    if c.meeting != nil { Button("Live Transcript…") { c.showLiveMeeting() } }
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct AboutTab: View {
    @ObservedObject var model: SettingsModel
    private var c: DictationController { model.controller }

    var body: some View {
        Form {
            Section {
                LabeledContent("Version", value: c.updater.currentVersion)
                HStack {
                    Button("Check for Updates") { Task { await c.updater.check(userInitiated: true); model.refresh() } }
                    if let release = c.updater.available { Button("Update to \(release.tag)") { c.updater.install(release) } }
                }
                if case .upToDate = c.updater.state { Text("You have the latest version.").font(.caption).foregroundStyle(.secondary) }
                if case let .failed(message) = c.updater.state { Text(message).font(.caption).foregroundStyle(.red) }
            }
            Section {
                HStack {
                    Button("Copy Diagnostics") { c.copyDiagnostics() }
                    Text("Settings and status for a bug report. Nothing you dictated, no API keys.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    Button("How to Use Murmur…") { c.showHowTo() }
                    Button("Setup…") { c.showSetup() }
                }
                HStack {
                    Button("Open Settings File") {
                        _ = try? Config.loadOrCreate(at: AppPaths.configFile)
                        NSWorkspace.shared.open(AppPaths.configFile)
                    }
                    Button("Reload Settings") { c.reloadConfig() }
                }
                if let failure = c.lastFailure {
                    Text("Last issue: " + failure).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
            }
        }
        .formStyle(.grouped)
    }
}
#endif
