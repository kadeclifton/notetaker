#if os(macOS)
import AppKit
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

        menu.addItem(statusLine())
        let dictation = item("Dictation", action: #selector(toggleEnabled), key: "e")
        dictation.state = controller.enabled ? .on : .off
        menu.addItem(dictation)

        menu.addItem(.separator())
        addMeetingItems(to: menu)
        menu.addItem(item("Library…", action: #selector(showLibrary), key: "l"))
        menu.addItem(submenu("Recent", recentMenu()))

        menu.addItem(.separator())
        menu.addItem(submenu("Snippets", snippetsMenu()))
        menu.addItem(submenu("Vocabulary", vocabularyMenu()))
        menu.addItem(item("Settings…", action: #selector(showSettingsWindow), key: ","))

        let update = updateItems()
        if !update.isEmpty {
            menu.addItem(.separator())
            update.forEach(menu.addItem)
        }

        menu.addItem(.separator())
        menu.addItem(item("Quit Murmur", action: #selector(quit), key: "q"))
    }

    /// One line saying what state Murmur is in, which opens the fix when something is wrong.
    private func statusLine() -> NSMenuItem {
        if controller.needsSetup {
            return item("⚠️ Finish Setup…", action: #selector(showSetup))
        }
        if let problem = controller.problems.first {
            let line = item("⚠️ " + problem, action: #selector(showProblems))
            line.toolTip = problem
            if line.title.count > 60 { line.title = String(line.title.prefix(57)) + "…" }
            return line
        }
        if !controller.enabled { return info("Dictation is off") }
        return info("Ready · " + controller.modesDescription)
    }

    /// Just above Quit, like other menu bar apps: the update downloads by itself, then one click
    /// installs it and restarts.
    private func updateItems() -> [NSMenuItem] {
        switch controller.updater.state {
        case let .downloading(release):
            return [info("Downloading Murmur \(release.tag)…")]
        case let .ready(release, _):
            return [info("An update is available (\(release.tag))"), whatsNew(release),
                    item("Restart to Update", action: #selector(restartToUpdate))].compactMap { $0 }
        case let .available(release):
            return [info("An update is available (\(release.tag))"), whatsNew(release),
                    item("Download and Restart", action: #selector(restartToUpdate))].compactMap { $0 }
        case let .installing(step):
            return [info(step)]
        case .idle, .checking, .upToDate, .failed:
            return []
        }
    }

    /// "What's New in v0.2.3 ▸" with one line per change; any of them opens the full notes.
    private func whatsNew(_ release: ReleaseInfo) -> NSMenuItem? {
        let highlights = release.highlights
        guard !highlights.isEmpty else { return nil }
        let submenu = NSMenu()
        for line in highlights { submenu.addItem(item("• " + line, action: #selector(openReleaseNotes))) }
        submenu.addItem(.separator())
        submenu.addItem(item("Full Release Notes…", action: #selector(openReleaseNotes)))
        let parent = NSMenuItem(title: "What's New in \(release.tag)", action: nil, keyEquivalent: "")
        parent.submenu = submenu
        return parent
    }

    @objc private func openReleaseNotes() {
        controller.updater.openReleasePage()
    }

    private func addMeetingItems(to menu: NSMenu) {
        if let status = controller.meetingStatus {
            menu.addItem(info("Meeting Notes: \(status)"))
        } else if let meeting = controller.meeting {
            menu.addItem(item("Stop Meeting Notes · \(MeetingTranscript.clock(meeting.elapsed))", action: #selector(stopMeeting), key: "m"))
            menu.addItem(item("Live Transcript…", action: #selector(showLiveMeeting)))
            if let warning = meeting.warnings.last { menu.addItem(info("⚠️ " + warning)) }
        } else {
            menu.addItem(item("Start Meeting Notes", action: #selector(startMeeting), key: "m"))
        }
    }

    /// The last few things Murmur inserted; click one to copy it again. Memory only.
    private func recentMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let undo = item("Undo Last Dictation", action: #selector(undoLastDictation))
        undo.isEnabled = controller.canUndoLastDictation
        undo.toolTip = "Sends ⌘Z to the app it went into. Or just say \u{201C}scratch that\u{201D}."
        menu.addItem(undo)
        let fix = item("Fix a Word…", action: #selector(addCorrection))
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
            let marker = entry.mode == .compose ? "✦ " : ""
            let choice = item(marker + entry.preview, action: #selector(copyRecent(_:)))
            choice.representedObject = entry.id.uuidString
            choice.toolTip = "\(formatter.localizedString(for: entry.date, relativeTo: Date())) · click to copy"
            menu.addItem(choice)
        }
        menu.addItem(.separator())
        menu.addItem(info("Click one to copy it. Kept only until Murmur quits."))
        menu.addItem(item("Clear", action: #selector(clearRecent)))
        return menu
    }

    /// Saved text: click one to type it where you are; say its phrase to do the same by voice.
    private func snippetsMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.addItem(item("Add Snippet…", action: #selector(addSnippet)))
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
        menu.addItem(item("Edit Snippets…", action: #selector(editSnippets)))
        return menu
    }

    /// Names and jargon Whisper should spell right.
    private func vocabularyMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.addItem(item("Add Word…", action: #selector(addVocabularyWord)))
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

    private func submenu(_ title: String, _ menu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = menu
        return item
    }

    private func item(_ title: String, action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    private func info(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        if title.count > 90 {
            item.toolTip = title
            item.title = String(title.prefix(87)) + "…"
        }
        return item
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
#endif
