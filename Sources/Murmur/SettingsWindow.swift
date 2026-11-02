#if os(macOS)
import AppKit
import SwiftUI
import MurmurCore

/// The settings people change most, without editing the settings file.
@MainActor
final class SettingsWindowController {
    let model: SettingsModel
    private var window: NSWindow?

    /// Room for the sidebar plus the pages at their usual width; the window can be made larger.
    static let size = CGSize(width: 780, height: 560)
    static let minSize = CGSize(width: 680, height: 460)

    init(controller: DictationController) {
        model = SettingsModel(controller: controller)
    }

    func show(tab: SettingsTab? = nil) {
        if let tab { model.tab = tab }
        model.refresh()
        if window == nil {
            let window = NSWindow(contentRect: NSRect(origin: .zero, size: Self.size),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                                  backing: .buffered, defer: false)
            window.title = "Murmur Settings"
            // Like System Settings: the sidebar runs to the top, the page's name is the window title.
            window.toolbarStyle = .unified
            let hosting = NSHostingView(rootView: SettingsView(model: model))
            hosting.sceneBridgingOptions = [.title, .toolbars]
            window.contentView = hosting
            window.contentMinSize = Self.minSize
            window.isReleasedWhenClosed = false
            window.setFrameAutosaveName("MurmurSettings")
            if window.frame.origin == .zero { window.center() }
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

    /// White on the tile's color, like System Settings.
    var symbol: String {
        switch self {
        case .general: return "gearshape.fill"
        case .speech: return "mic.fill"
        case .writing: return "sparkles"
        case .snippets: return "text.badge.plus"
        case .meetings: return "person.2.wave.2.fill"
        case .about: return "info"
        }
    }

    var color: Color {
        switch self {
        case .general: return .gray
        case .speech: return .red
        case .writing: return .purple
        case .snippets: return .blue
        case .meetings: return .green
        case .about: return .indigo
        }
    }

    /// The line under the page's title.
    var subtitle: String {
        switch self {
        case .general: return "Your hotkey, the pill, and how Murmur starts."
        case .speech: return "How Murmur hears you: microphone, engine, language, and the words it should know."
        case .writing: return "Clean Up and Compose: which models write for you, and how long they stay loaded."
        case .snippets: return "Say a short phrase, get a whole block of text."
        case .meetings: return "Notes for your calls: transcripts, summaries and the shortcut."
        case .about: return "Version, updates, help, and the settings file."
        }
    }

    /// Words the sidebar search finds the page by, besides its name and subtitle.
    var keywords: [String] {
        switch self {
        case .general: return ["hotkey", "shortcut", "fn", "key", "paste last", "stats", "words", "launch at login",
                               "startup", "sounds", "pill", "position", "dictation on", "off"]
        case .speech: return ["microphone", "mic", "input", "engine", "whisper", "apple", "groq", "openai", "language",
                              "model", "memory", "unload", "vocabulary", "corrections", "fix a word", "transcription"]
        case .writing: return ["clean up", "cleanup", "compose", "ollama", "lm studio", "llm", "model", "library",
                               "neural engine", "summaries", "keep loaded"]
        case .snippets: return ["text replacement", "phrase", "insert", "signature", "email", "scratch that"]
        case .meetings: return ["call", "zoom", "facetime", "teams", "meet", "transcript", "summary", "audio",
                                "offer", "notes", "shortcut", "live transcript"]
        case .about: return ["version", "update", "beta", "release notes", "what's new", "diagnostics", "help",
                             "setup", "settings file", "api keys", "reload", "remove", "uninstall", "privacy", "problem"]
        }
    }

    func matches(_ query: String) -> Bool {
        let words = query.lowercased().split(separator: " ").map(String.init)
        let haystack = ([rawValue, subtitle] + keywords).joined(separator: " ").lowercased()
        return words.allSatisfy { haystack.contains($0) }
    }
}

/// A page's icon: a white symbol on a colored rounded square.
struct SettingsIcon: View {
    let tab: SettingsTab
    var size: CGFloat = 20

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.25, style: .continuous)
            .fill(tab.color.gradient)
            .frame(width: size, height: size)
            .overlay {
                Image(systemName: tab.symbol)
                    .font(.system(size: size * 0.55, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .shadow(color: .black.opacity(0.12), radius: size * 0.04, y: size * 0.03)
            .accessibilityHidden(true)
    }
}

/// The top of each page: its icon, name and what it is for, as in System Settings.
private struct PageHeader: View {
    let tab: SettingsTab

    var body: some View {
        VStack(spacing: 6) {
            if tab == .about {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 64, height: 64).accessibilityHidden(true)
            } else {
                SettingsIcon(tab: tab, size: 48)
            }
            Text(tab.rawValue).font(.title2.weight(.semibold))
            Text(tab.subtitle)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .accessibilityElement(children: .combine)
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

    /// The first row that cannot be saved, as a message for the Snippets tab.
    var snippetProblem: String? {
        snippets.lazy.map(\.snippet).filter { !($0.say.isEmpty && $0.insert.isEmpty) }
            .compactMap(VoiceCommands.problem(with:)).first
    }

    func saveSnippets() {
        guard snippetProblem == nil else { return }
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
    @State private var query = ""

    private var matches: [SettingsTab] {
        query.isEmpty ? SettingsTab.allCases : SettingsTab.allCases.filter { $0.matches(query) }
    }

    /// A sidebar with every section named and searchable, like System Settings, rather than a tab
    /// bar whose icons can end up folded behind a » button.
    var body: some View {
        NavigationSplitView {
            List(selection: Binding(get: { model.tab }, set: { if let tab = $0 { model.tab = tab } })) {
                ForEach(matches, id: \.self) { tab in
                    Label { Text(tab.rawValue) } icon: { SettingsIcon(tab: tab) }
                        .tag(tab)
                }
            }
            .listStyle(.sidebar)
            .searchable(text: $query, placement: .sidebar, prompt: "Search")
            .overlay {
                if matches.isEmpty { ContentUnavailableView.search(text: query) }
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 210, max: 260)
            .toolbar(removing: .sidebarToggle)
        } detail: {
            page
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .navigationTitle(model.tab.rawValue)
        }
        .frame(minWidth: SettingsWindowController.minSize.width, minHeight: SettingsWindowController.minSize.height)
        // Searching jumps to the first page that has it, unless the open page does.
        .onChange(of: query) { _, _ in
            if let first = matches.first, !matches.contains(model.tab) { model.tab = first }
        }
    }

    @ViewBuilder
    private var page: some View {
        switch model.tab {
        case .general: GeneralTab(model: model)
        case .speech: SpeechTab(model: model)
        case .writing: WritingTab(model: model)
        case .snippets: SnippetsTab(model: model)
        case .meetings: MeetingsTab(model: model)
        case .about: AboutTab(model: model)
        }
    }
}

// MARK: - Tabs

private struct GeneralTab: View {
    @ObservedObject var model: SettingsModel
    private var c: DictationController { model.controller }

    var body: some View {
        Form {
            Section { PageHeader(tab: .general) }
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
                LabeledContent("Paste last again") {
                    Text(c.pasteLastShortcutName ?? "off").font(.system(.body, design: .rounded).weight(.semibold))
                }
                Text("Types your last dictation again, wherever you are. Change it with insertion.pasteLastShortcut in the settings file.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            StatsSection(controller: c)
            Section {
                Toggle("Dictation on", isOn: Binding(get: { c.enabled }, set: { c.enabled = $0 }))
                Toggle("Launch at login", isOn: Binding(get: { LoginItem.isEnabled }, set: { on in _ = try? LoginItem.set(on) }))
                if LoginItem.needsApproval {
                    Text("Approve Murmur in System Settings → General → Login Items.").font(.caption).foregroundStyle(.orange)
                }
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
    @State private var newHeard = ""
    @State private var newWrite = ""
    private var c: DictationController { model.controller }

    var body: some View {
        Form {
            Section { PageHeader(tab: .speech) }
            Section {
                Picker("Microphone", selection: Binding(get: { c.microphoneUID ?? "" }, set: { c.setMicrophone($0.isEmpty ? nil : $0) })) {
                    Text("System Default" + (c.defaultMicrophoneName.map { " (\($0))" } ?? "")).tag("")
                    ForEach(c.microphones, id: \.uid) { Text($0.name).tag($0.uid) }
                }
                Picker("Speech recognition", selection: Binding(get: { c.speechEngine }, set: { c.setSpeechEngine($0) })) {
                    Text("Automatic").tag(TranscriptionEngine.auto)
                    Text("Whisper on this Mac").tag(TranscriptionEngine.local)
                    if SystemSpeech.isAvailable || c.speechEngine == .apple {
                        Text("Apple, built into macOS").tag(TranscriptionEngine.apple)
                    }
                    if c.speechEngine == .groq { Text("Groq").tag(TranscriptionEngine.groq) }
                    if c.speechEngine == .openai { Text("OpenAI").tag(TranscriptionEngine.openai) }
                }
                Text(Self.engineNote(c.speechEngine, appleAvailable: SystemSpeech.isAvailable))
                    .font(.caption).foregroundStyle(.secondary)
                Picker("Language", selection: Binding(get: { c.speechLanguage }, set: { c.setSpeechLanguage($0) })) {
                    if !SpeechLanguage.choices.contains(where: { $0.code == c.speechLanguage }) {
                        Text(c.speechLanguage).tag(c.speechLanguage)
                    }
                    ForEach(SpeechLanguage.choices) { Text($0.name).tag($0.code) }
                }
                if SpeechLanguage.needsMultilingualModel(c.speechLanguage), c.usesLocalWhisper {
                    Text("Fastest and Balanced understand English only, so other languages use Most accurate.")
                        .font(.caption).foregroundStyle(.secondary)
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
                    if c.keepsSpeechModelLoaded {
                        Picker("Free memory when idle", selection: Binding(get: { c.unloadAfterMinutes },
                                                                            set: { c.setUnloadAfterMinutes($0) })) {
                            if !Self.unloadChoices.contains(c.unloadAfterMinutes) {
                                Text("After \(Self.minutes(c.unloadAfterMinutes)) minutes").tag(c.unloadAfterMinutes)
                            }
                            Text("After 5 minutes").tag(5.0)
                            Text("After 15 minutes").tag(15.0)
                            Text("After 30 minutes").tag(30.0)
                            Text("Never").tag(0.0)
                        }
                        Text(c.unloadAfterMinutes > 0
                             ? "The speech model uses memory while loaded. It loads again when you press \(c.hotkeyDescription), so the first dictation after a break is about a second slower."
                             : "The speech model stays loaded while Murmur runs: every dictation starts instantly, and it keeps using memory.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
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
                            .accessibilityLabel("Remove \(word)")
                            .buttonStyle(.borderless)
                    }
                }
            }
            Section("Corrections") {
                Text("Words it keeps getting wrong, fixed in every dictation and meeting: \u{201C}cloud code\u{201D} → \u{201C}Claude Code\u{201D}.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    TextField("It writes", text: $newHeard).accessibilityLabel("What it writes")
                    Image(systemName: "arrow.right").foregroundStyle(.secondary).accessibilityHidden(true)
                    TextField("Should be", text: $newWrite).accessibilityLabel("What it should be").onSubmit(addCorrection)
                    Button("Add", action: addCorrection)
                        .disabled(newHeard.trimmingCharacters(in: .whitespaces).isEmpty || newWrite.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                ForEach(c.corrections, id: \.self) { correction in
                    HStack {
                        Text(correction.heard).foregroundStyle(.secondary)
                        Image(systemName: "arrow.right").foregroundStyle(.secondary).accessibilityHidden(true)
                        Text(correction.write)
                        Spacer()
                        Button { c.removeCorrection(correction) } label: { Image(systemName: "minus.circle") }
                            .accessibilityLabel("Remove correction \(correction.heard)")
                            .buttonStyle(.borderless)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private static let unloadChoices: [Double] = [5, 15, 30, 0]

    private static func minutes(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(format: "%.1f", value)
    }

    private func add() {
        c.addVocabulary(newWord)
        newWord = ""
    }

    private func addCorrection() {
        c.addCorrection(heard: newHeard, write: newWrite)
        newHeard = ""
        newWrite = ""
    }

    static func engineNote(_ engine: TranscriptionEngine, appleAvailable: Bool) -> String {
        switch engine {
        case .auto: return "Groq or OpenAI if you added an API key, otherwise Whisper on this Mac."
        case .local: return "Whisper runs on this Mac with the speech model below. Best with names and vocabulary."
        case .apple:
            return appleAvailable
                ? "Built into macOS: no model to download, no memory used while idle, and your words show as you talk. Vocabulary is Whisper's; corrections work with both."
                : "Needs macOS 26 or later. Pick Whisper on this Mac."
        case .groq, .openai: return "Sent to \(engine == .groq ? "Groq" : "OpenAI") with your API key."
        }
    }
}

/// Words dictated and typing time saved, counted on this Mac only.
private struct StatsSection: View {
    let controller: DictationController
    @State private var confirmReset = false

    var body: some View {
        let week = controller.stats.summary(lastDays: 7)
        let quarter = controller.stats.summary(lastDays: UsageStats.keepDays)
        Section("Your dictation") {
            LabeledContent("This week", value: Self.describe(week))
            LabeledContent("Last 90 days", value: Self.describe(quarter))
            HStack {
                Text("Time saved compares your words with typing at \(Int(UsageStats.typingWPM)) words a minute. Counted on this Mac only.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Reset") { confirmReset = true }.controlSize(.small)
            }
        }
        .confirmationDialog("Reset your dictation stats?", isPresented: $confirmReset) {
            Button("Reset", role: .destructive) { controller.resetStats() }
        }
    }

    static func describe(_ summary: UsageStats.Summary) -> String {
        guard summary.words > 0 else { return "nothing yet" }
        let words = summary.words.formatted()
        let minutes = Int(summary.minutesSaved.rounded())
        let saved = minutes >= 60 ? "\(minutes / 60) h \(minutes % 60) min" : "\(minutes) min"
        return "\(words) words · about \(saved) saved"
    }
}

/// Cleanup (hotkey + ⌃) and Compose (hotkey + ⌃⌥): which models, and how long they stay loaded.
private struct WritingTab: View {
    @ObservedObject var model: SettingsModel
    private var c: DictationController { model.controller }

    var body: some View {
        Form {
            Section { PageHeader(tab: .writing) }
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
                HStack {
                    Button("Library…") { c.showLibrary() }
                    Button("Open Library Folder") { c.openLibraryFolder() }
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
            PageHeader(tab: .snippets)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.quinary))
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
                                .accessibilityLabel("Phrase to say")
                            TextEditor(text: $draft.insert)
                                .accessibilityLabel("Text to insert")
                                .font(.body)
                                .frame(height: 54)
                                .scrollContentBackground(.hidden)
                                .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.05)))
                            Button { model.removeSnippet(draft.id) } label: { Image(systemName: "minus.circle") }
                                .accessibilityLabel(draft.say.isEmpty ? "Remove snippet" : "Remove snippet \(draft.say)")
                                .buttonStyle(.borderless)
                        }
                    }
                }
            }
            HStack {
                Button("Add Snippet") { model.snippets.append(SnippetDraft(Snippet(say: "", insert: ""))) }
                Spacer()
                if let problem = model.snippetProblem {
                    Text(problem).font(.caption).foregroundStyle(.red)
                } else if model.snippetsChanged {
                    Text("Not saved yet").font(.caption).foregroundStyle(.secondary)
                }
                Button("Save") { model.saveSnippets() }
                    .keyboardShortcut("s")
                    .disabled(!model.snippetsChanged || model.snippetProblem != nil)
            }
        }
        .padding(20)
    }
}

private struct MeetingsTab: View {
    @ObservedObject var model: SettingsModel
    private var c: DictationController { model.controller }

    var body: some View {
        Form {
            Section { PageHeader(tab: .meetings) }
            Section {
                Toggle("Offer to take notes when a call starts", isOn: Binding(get: { c.config.meeting.offerWhenCallStarts }, set: { on in
                    c.editSettings("meeting", "offerWhenCallStarts", json: on ? "true" : "false") { $0.meeting.offerWhenCallStarts == on }
                }))
                Text("When Zoom, Teams, FaceTime, Slack or a browser starts using the microphone, Murmur asks. It never records without you saying yes.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Offer to stop when the call ends", isOn: Binding(get: { c.config.meeting.offerToStopWhenCallEnds }, set: { on in
                    c.editSettings("meeting", "offerToStopWhenCallEnds", json: on ? "true" : "false") { $0.meeting.offerToStopWhenCallEnds == on }
                }))
                Toggle("Record the call's audio, not just my mic", isOn: Binding(get: { c.config.meeting.captureSystemAudio }, set: { on in
                    c.editSettings("meeting", "captureSystemAudio", json: on ? "true" : "false") { $0.meeting.captureSystemAudio == on }
                }))
                Toggle("Write a summary when it ends", isOn: Binding(get: { c.config.meeting.summarize }, set: { on in
                    c.editSettings("meeting", "summarize", json: on ? "true" : "false") { $0.meeting.summarize == on }
                }))
                LabeledContent("Summaries by", value: c.summaryName)
            }
            Section {
                LabeledContent("Start or stop") {
                    Text(c.meetingShortcutName ?? "off").font(.system(.body, design: .rounded).weight(.semibold))
                }
                Text("Starts Meeting Notes from anywhere, and stops and summarizes them. Change it with meeting.shortcut in the settings file.")
                    .font(.caption).foregroundStyle(.secondary)
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
    @State private var confirmRemove = false
    private var c: DictationController { model.controller }

    var body: some View {
        Form {
            Section { PageHeader(tab: .about) }
            Section {
                LabeledContent("Version", value: c.updater.currentVersion)
                HStack(spacing: 16) {
                    Link("Privacy", destination: URL(string: "https://github.com/kadeclifton/notetaker/blob/main/PRIVACY.md")!)
                    Link("Report a Problem", destination: URL(string: "https://github.com/kadeclifton/notetaker/issues/new/choose")!)
                }
                .font(.callout)
                HStack {
                    Button("Check for Updates") { Task { await c.updater.check(userInitiated: true); model.refresh() } }
                    if let release = c.updater.available {
                        Button(c.updater.isReady ? "Restart to Update (\(release.tag))" : "Update to \(release.tag)") { c.updater.install(release) }
                    }
                }
                if let release = c.updater.available, !release.highlights.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("What's new in \(release.tag)").font(.caption.weight(.semibold))
                        ForEach(release.highlights, id: \.self) { Text("• " + $0).font(.caption) }
                        Button("Full Release Notes…") { c.updater.openReleasePage() }
                            .buttonStyle(.link).font(.caption)
                    }
                }
                if case .upToDate = c.updater.state { Text("You have the latest version.").font(.caption).foregroundStyle(.secondary) }
                if case let .failed(message) = c.updater.state { Text(message).font(.caption).foregroundStyle(.red) }
                Picker("Updates", selection: Binding(get: { c.config.updates.betaUpdates }, set: { beta in
                    c.editSettings("updates", "betaUpdates", json: beta ? "true" : "false") { $0.updates.betaUpdates == beta }
                })) {
                    Text("Release").tag(false)
                    Text("Beta").tag(true)
                }
                .pickerStyle(.segmented)
                Text(c.config.updates.betaUpdates
                     ? "Beta: new versions arrive first, before everyone else. They may have rough edges."
                     : "Release: tested versions only. Switch to Beta to try new ones early.")
                    .font(.caption).foregroundStyle(.secondary)
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
                    Button("Open API Keys") { c.openAPIKeys() }
                    Button("Reload Settings") { c.reloadConfig() }
                }
                ForEach(c.problems, id: \.self) { problem in
                    Text("⚠️ " + problem).font(.caption).foregroundStyle(.orange).textSelection(.enabled)
                }
                if let failure = c.lastFailure {
                    Text("Last issue: " + failure).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
            }
            Section {
                HStack {
                    Button("Remove Murmur…", role: .destructive) { confirmRemove = true }
                    Text("Deletes Murmur, its settings, API keys, speech models and permissions.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .confirmationDialog("Remove Murmur from this Mac?", isPresented: $confirmRemove) {
            Button("Remove Murmur", role: .destructive) { c.removeMurmur() }
        } message: {
            Text("Murmur moves to the Trash with its settings, API keys, speech models and permissions. Your Library and meeting notes in Documents stay.")
        }
    }
}
#endif
