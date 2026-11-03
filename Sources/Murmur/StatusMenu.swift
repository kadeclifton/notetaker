#if os(macOS)
import AppKit
import SwiftUI
import MurmurCore

/// The menu bar icon and its menu.
@MainActor
final class StatusMenu: NSObject, NSMenuDelegate {
    private let controller: DictationController
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()
    /// Pulses the wave while a dictation is being transcribed, cleaned up or composed.
    private var pulseTimer: Timer?
    private var pulseDim = false

    init(controller: DictationController) {
        self.controller = controller
        super.init()
        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.menu = menu
        updateIcon()
    }

    func updateIcon() {
        // Murmur's own wave for its normal states; system symbols where something needs attention.
        let image: NSImage?
        if controller.meeting != nil {
            image = symbol("record.circle")
        } else if !controller.enabled {
            image = MenuBarIcon.image(.off)
        } else if controller.isRecording {
            image = MenuBarIcon.image(.recording)
        } else if !controller.hotkeyIsListening || !controller.problems.isEmpty {
            image = symbol("exclamationmark.triangle")
        } else if controller.isWorking {
            image = MenuBarIcon.image(pulseDim ? .off : .idle)
        } else {
            image = MenuBarIcon.image(.idle)
        }
        updatePulse()
        // While a meeting records, the menu bar shows how long it has been going.
        statusItem.button?.title = controller.meeting.map { " " + MeetingTranscript.clock($0.elapsed) } ?? ""
        statusItem.button?.image = image
        statusItem.button?.setAccessibilityLabel(controller.meeting != nil ? "Murmur, recording meeting notes"
            : controller.isRecording ? "Murmur, listening" : "Murmur")
        statusItem.button?.imagePosition = .imageLeft
        statusItem.button?.toolTip = controller.enabled ? "Murmur: " + controller.modesDescription : "Murmur is off"
    }

    private func updatePulse() {
        let working = controller.isWorking && controller.enabled && !controller.isRecording && controller.meeting == nil
        if working, pulseTimer == nil {
            pulseTimer = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: true) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.pulseDim.toggle()
                    self.updateIcon()
                }
            }
        } else if !working, let timer = pulseTimer {
            timer.invalidate()
            pulseTimer = nil
            pulseDim = false
        }
    }

    private func symbol(_ name: String) -> NSImage? {
        let image = NSImage(systemSymbolName: name, accessibilityDescription: "Murmur")
        image?.isTemplate = true
        return image
    }

    // Rebuilt every time it opens so it always reflects current state. The top level stays short:
    // what state Murmur is in, the things you do (dictate, record a meeting, snippets), and Settings.
    // Everything else (models, microphone, pill, files, updates, diagnostics) lives in the Settings window.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        controller.detectLocalLLM()

        menu.addItem(headerItem())
        if let fix = fixItem() { menu.addItem(fix) }
        menu.addItem(.separator())

        let dictation = item("Dictation", action: #selector(toggleEnabled), key: "e", symbol: "mic")
        dictation.state = controller.enabled ? .on : .off
        menu.addItem(dictation)
        addMeetingItems(to: menu)

        menu.addItem(.separator())
        menu.addItem(item("Library…", action: #selector(showLibrary), key: "l", symbol: "books.vertical"))
        menu.addItem(submenu("Recent", recentMenu(), symbol: "clock.arrow.circlepath"))
        menu.addItem(submenu("Snippets", snippetsMenu(), symbol: "text.badge.plus"))
        menu.addItem(submenu("Vocabulary", vocabularyMenu(), symbol: "character.book.closed"))

        let update = updateItems()
        if !update.isEmpty {
            menu.addItem(.separator())
            update.forEach(menu.addItem)
        }

        menu.addItem(.separator())
        menu.addItem(item("Settings…", action: #selector(showSettingsWindow), key: ",", symbol: "gearshape"))
        menu.addItem(item("Quit Murmur", action: #selector(quit), key: "q", symbol: "power"))
    }

    /// The card at the top: Murmur's state, today's dictation, and which keys do what.
    private func headerItem() -> NSMenuItem {
        let (status, color) = headerStatus
        let today = controller.stats.summary(lastDays: 1)
        let minutes = Int(today.minutesSaved.rounded())
        let line = today.words == 0
            ? "Nothing dictated yet today"
            : "\(today.words.formatted()) words today" + (minutes > 0 ? " · \(minutes) min saved" : "")
        let header = MenuHeader(status: status, color: color, today: line,
                                hints: controller.enabled ? controller.modeHints : [])
        let view = NSHostingView(rootView: header)
        view.frame = NSRect(origin: .zero, size: view.fittingSize)
        view.setAccessibilityElement(true)
        view.setAccessibilityLabel("Murmur, \(status). \(line).")
        let item = NSMenuItem()
        item.view = view
        return item
    }

    private var headerStatus: (String, Color) {
        if controller.needsSetup { return ("Set Up", .orange) }
        if !controller.problems.isEmpty { return ("Needs Attention", .orange) }
        if controller.meeting != nil { return ("Recording", .red) }
        if controller.isRecording { return ("Listening", .red) }
        if !controller.enabled { return ("Off", .gray) }
        if controller.isWorking { return ("Working", .blue) }
        return ("Ready", .green)
    }

    /// Under the card when something needs fixing; it opens the fix.
    private func fixItem() -> NSMenuItem? {
        if controller.needsSetup {
            return item("Finish Setup…", action: #selector(showSetup), symbol: "exclamationmark.triangle.fill")
        }
        guard let problem = controller.problems.first else { return nil }
        let line = item(problem, action: #selector(showProblems), symbol: "exclamationmark.triangle.fill")
        line.toolTip = problem
        if line.title.count > 60 { line.title = String(line.title.prefix(57)) + "…" }
        return line
    }

    /// Just above Quit, like other menu bar apps: the update downloads by itself, then one click
    /// installs it and restarts.
    private func updateItems() -> [NSMenuItem] {
        switch controller.updater.state {
        case let .downloading(release):
            return [info("Downloading Murmur \(release.tag)…", symbol: "arrow.down.circle")]
        case let .ready(release, _):
            return [info("An update is available (\(release.tag))", symbol: "arrow.down.circle"), whatsNew(release),
                    item("Restart to Update", action: #selector(restartToUpdate), symbol: "arrow.clockwise")].compactMap { $0 }
        case let .available(release):
            return [info("An update is available (\(release.tag))", symbol: "arrow.down.circle"), whatsNew(release),
                    item("Download and Restart", action: #selector(restartToUpdate), symbol: "arrow.clockwise")].compactMap { $0 }
        case let .installing(step):
            return [info(step, symbol: "arrow.down.circle")]
        case .idle, .checking, .upToDate, .failed:
            return []
        }
    }

    /// "What's New in v0.2.3 ▸" with one line per change; any of them opens the full notes.
    private func whatsNew(_ release: ReleaseInfo) -> NSMenuItem? {
        let highlights = release.highlights
        guard !highlights.isEmpty else { return nil }
        let notes = NSMenu()
        for line in highlights { notes.addItem(item("• " + line, action: #selector(openReleaseNotes))) }
        notes.addItem(.separator())
        notes.addItem(item("Full Release Notes…", action: #selector(openReleaseNotes)))
        return submenu("What's New in \(release.tag)", notes, symbol: "sparkles")
    }

    @objc private func openReleaseNotes() {
        controller.updater.openReleasePage()
    }

    private func addMeetingItems(to menu: NSMenu) {
        if let status = controller.meetingStatus {
            menu.addItem(info("Meeting Notes: \(status)", symbol: "hourglass"))
        } else if let meeting = controller.meeting {
            menu.addItem(item("Stop Meeting Notes · \(MeetingTranscript.clock(meeting.elapsed))", action: #selector(stopMeeting),
                              key: "m", symbol: "stop.circle"))
            menu.addItem(item("Live Transcript…", action: #selector(showLiveMeeting), symbol: "text.bubble"))
            if let warning = meeting.warnings.last { menu.addItem(info(warning, symbol: "exclamationmark.triangle")) }
        } else {
            menu.addItem(item("Start Meeting Notes", action: #selector(startMeeting), key: "m", symbol: "record.circle"))
        }
    }

    /// The last few things Murmur inserted; click one to copy it again. Memory only.
    private func recentMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let undo = item("Undo Last Dictation", action: #selector(undoLastDictation), symbol: "arrow.uturn.backward")
        undo.isEnabled = controller.canUndoLastDictation
        undo.toolTip = "Sends ⌘Z to the app it went into. Or just say \u{201C}scratch that\u{201D}."
        menu.addItem(undo)
        let fix = item("Fix a Word…", action: #selector(addCorrection), symbol: "character.cursor.ibeam")
        fix.toolTip = "Always write a word it keeps getting wrong the way it should be."
        menu.addItem(fix)
        menu.addItem(.separator())
        let items = controller.recent.items
        if items.isEmpty {
            menu.addItem(info("Nothing yet. Your last 10 dictations appear here."))
            return menu
        }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        for entry in items {
            let choice = item(entry.preview, action: #selector(copyRecent(_:)),
                              symbol: entry.mode == .compose ? "sparkles" : "text.quote")
            choice.representedObject = entry.id.uuidString
            choice.toolTip = "\(formatter.localizedString(for: entry.date, relativeTo: Date())) · click to copy"
            menu.addItem(choice)
        }
        menu.addItem(.separator())
        menu.addItem(info("Click one to copy it. Kept only until Murmur quits."))
        menu.addItem(item("Clear", action: #selector(clearRecent), symbol: "trash"))
        return menu
    }

    /// Saved text: click one to type it where you are; say its phrase to do the same by voice.
    private func snippetsMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.addItem(item("Add Snippet…", action: #selector(addSnippet), symbol: "plus"))
        let snippets = controller.snippets
        if snippets.isEmpty {
            menu.addItem(info("Say a phrase, get saved text: \u{201C}my email\u{201D} → your address"))
        } else {
            menu.addItem(.separator())
            for (index, snippet) in snippets.enumerated() {
                let preview = snippet.insert.split(whereSeparator: \.isNewline).joined(separator: " ")
                let short = preview.count > 40 ? String(preview.prefix(37)) + "…" : preview
                let entry = item("\u{201C}\(snippet.say)\u{201D}  →  \(short)", action: #selector(insertSnippet(_:)))
                entry.representedObject = index
                entry.toolTip = "Click to type it, or say \u{201C}\(snippet.say)\u{201D} on its own"
                menu.addItem(entry)
            }
            menu.addItem(info("Click one to type it where you are"))
        }
        menu.addItem(.separator())
        menu.addItem(item("Edit Snippets…", action: #selector(editSnippets), symbol: "pencil"))
        return menu
    }

    /// Names and jargon Whisper should spell right.
    private func vocabularyMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.addItem(item("Add Word…", action: #selector(addVocabularyWord), symbol: "plus"))
        let words = controller.vocabulary
        if words.isEmpty {
            menu.addItem(info("Names and jargon Whisper keeps getting wrong"))
        } else {
            menu.addItem(.separator())
            for word in words {
                let entry = item(word, action: #selector(removeVocabularyWord(_:)))
                entry.representedObject = word
                entry.toolTip = "Click to remove"
                menu.addItem(entry)
            }
            menu.addItem(info("Click a word to remove it"))
        }
        return menu
    }

    private func submenu(_ title: String, _ menu: NSMenu, symbol: String? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = menu
        item.image = symbol.flatMap(Self.icon)
        return item
    }

    private func item(_ title: String, action: Selector, key: String = "", symbol: String? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        item.image = symbol.flatMap(Self.icon)
        return item
    }

    private func info(_ title: String, symbol: String? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        item.image = symbol.flatMap(Self.icon)
        if title.count > 90 {
            item.toolTip = title
            item.title = String(title.prefix(87)) + "…"
        }
        return item
    }

    /// An SF Symbol sized for a menu row; macOS tints it with the row's text.
    private static func icon(_ name: String) -> NSImage? {
        let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 13, weight: .regular))
        image?.isTemplate = true
        return image
    }

    // MARK: Actions

    @objc private func toggleEnabled() {
        controller.enabled.toggle()
    }

    @objc private func showSetup() {
        controller.showSetup()
    }

    /// The ⚠️ status line: Settings → About lists every problem next to the settings file.
    @objc private func showProblems() {
        controller.showSettings(tab: .about)
    }

    /// One click, no questions, unless a meeting is recording: it would be saved without its summary.
    @objc private func restartToUpdate() {
        guard let release = controller.updater.available else { return }
        if controller.meeting != nil {
            let alert = NSAlert()
            alert.messageText = "Restart to update now?"
            alert.informativeText = "The meeting being recorded is saved first, without its summary."
            alert.addButton(withTitle: "Restart to Update")
            alert.addButton(withTitle: "Later")
            NSApp.activate(ignoringOtherApps: true)
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        controller.updater.install(release)
    }

    @objc private func copyRecent(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let id = UUID(uuidString: raw) else { return }
        controller.copyRecent(id)
    }

    @objc private func clearRecent() {
        controller.clearRecent()
    }

    @objc private func addVocabularyWord() {
        let alert = NSAlert()
        alert.messageText = "Add to Vocabulary"
        alert.informativeText = "A name or term Whisper keeps misspelling, written the way it should appear."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.placeholderString = "e.g. Kubernetes, Siobhan, Murmur"
        alert.accessoryView = field
        alert.addButton(withTitle: "Add")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        controller.addVocabulary(field.stringValue)
    }

    /// "It writes … / Should be …": a correction applied to every dictation from now on.
    @objc private func addCorrection() {
        let alert = NSAlert()
        alert.messageText = "Fix a Word"
        alert.informativeText = "From now on, whenever it writes the first, it writes the second instead."
        let heard = NSTextField(frame: NSRect(x: 0, y: 30, width: 260, height: 24))
        heard.placeholderString = "It writes, e.g. cloud code"
        let write = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        write.placeholderString = "Should be, e.g. Claude Code"
        let box = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: 54))
        box.addSubview(heard)
        box.addSubview(write)
        heard.nextKeyView = write
        alert.accessoryView = box
        alert.addButton(withTitle: "Add")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = heard
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        controller.addCorrection(heard: heard.stringValue, write: write.stringValue)
    }

    @objc private func removeVocabularyWord(_ sender: NSMenuItem) {
        guard let word = sender.representedObject as? String else { return }
        controller.removeVocabulary(word)
    }

    @objc private func addSnippet() {
        let alert = NSAlert()
        alert.messageText = "Add a Snippet"
        alert.informativeText = "Say the phrase on its own and the text is typed instead."
        let say = NSTextField(frame: NSRect(x: 0, y: 64, width: 300, height: 24))
        say.placeholderString = "When I say… (e.g. my email)"
        let text = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 56))
        text.placeholderString = "Type this (e.g. name@example.com)"
        text.usesSingleLineMode = false
        text.cell?.wraps = true
        let box = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 88))
        box.addSubview(say)
        box.addSubview(text)
        alert.accessoryView = box
        alert.addButton(withTitle: "Add")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = say
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        if let problem = controller.addSnippet(Snippet(say: say.stringValue, insert: text.stringValue)) {
            showAlert(problem)
        }
    }

    @objc private func insertSnippet(_ sender: NSMenuItem) {
        guard let index = sender.representedObject as? Int, controller.snippets.indices.contains(index) else { return }
        controller.insertSnippet(controller.snippets[index])
    }

    @objc private func editSnippets() {
        controller.showSettings(tab: .snippets)
    }

    @objc private func showSettingsWindow() {
        controller.showSettings()
    }

    @objc private func showLiveMeeting() {
        controller.showLiveMeeting()
    }

    @objc private func undoLastDictation() {
        let message = controller.undoLastDictation()
        if message != "Undone" { showAlert(message + ".") }
    }

    @objc private func showLibrary() {
        controller.showLibrary()
    }


    @objc private func startMeeting() {
        controller.startMeeting()
    }

    @objc private func stopMeeting() {
        controller.stopMeeting()
    }

    @objc private func quit() {
        Permissions.cancelReopen()
        NSApp.terminate(nil)
    }

    private func showAlert(_ text: String) {
        let alert = NSAlert()
        alert.messageText = "Murmur"
        alert.informativeText = text
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}

/// The top of the menu, as a card: Murmur's bars and state, today's dictation, and key caps for
/// what each key combination does.
struct MenuHeader: View {
    let status: String
    let color: Color
    let today: String
    let hints: [(keys: String, action: String)]

    static let width: CGFloat = 300

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                BrandBars()
                Text("Murmur").font(.system(size: 13, weight: .semibold))
                Spacer(minLength: 8)
                HStack(spacing: 5) {
                    Circle().fill(color).frame(width: 7, height: 7)
                    Text(status).font(.system(size: 11, weight: .medium))
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Capsule().fill(color.opacity(0.15)))
            }
            Text(today).font(.system(size: 12)).foregroundStyle(.secondary)
            if !hints.isEmpty {
                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 5) {
                    ForEach(Array(stride(from: 0, to: hints.count, by: 2)), id: \.self) { row in
                        GridRow {
                            hint(hints[row])
                            if row + 1 < hints.count { hint(hints[row + 1]) }
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 8)
        .padding(.bottom, 6)
        .frame(width: Self.width, alignment: .leading)
    }

    private func hint(_ hint: (keys: String, action: String)) -> some View {
        HStack(spacing: 5) {
            KeyCap(hint.keys)
            Text(hint.action).font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }
}

/// Murmur's 13 bars in its purple.
private struct BrandBars: View {
    var body: some View {
        HStack(alignment: .center, spacing: 1) {
            ForEach(MenuBarIcon.heights.indices, id: \.self) { index in
                Capsule().frame(width: 1.5, height: Self.height(index))
            }
        }
        .frame(height: 12)
        .foregroundStyle(Color.purple.gradient)
        .accessibilityHidden(true)
    }

    static func height(_ index: Int) -> CGFloat {
        max(1.5, 12 * MenuBarIcon.heights[index])
    }
}
#endif
