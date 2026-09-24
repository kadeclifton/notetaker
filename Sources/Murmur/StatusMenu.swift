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
    // Speech model, microphone and the writing models live in the Settings window.
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
        menu.addItem(submenu("More", settingsMenu()))
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
            let line = item("⚠️ " + problem, action: #selector(openSettings))
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
            let notes = info("An update is available (\(release.tag))")
            return [notes, item("Restart to Update", action: #selector(restartToUpdate))]
        case let .available(release):
            return [info("An update is available (\(release.tag))"), item("Download and Restart", action: #selector(restartToUpdate))]
        case let .installing(step):
            return [info(step)]
        case .idle, .checking, .upToDate, .failed:
            return []
        }
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

    /// Where the Listening/Transcribing pill appears. Dragging the pill picks "Where I Dragged It".
    private func pillPositionMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let current = controller.pillPosition
        for position in PillPosition.allCases {
            let choice = item(position.title, action: #selector(setPillPosition(_:)))
            choice.representedObject = position.rawValue
            choice.state = position == current ? .on : .off
            menu.addItem(choice)
            if position == .bottomRight { menu.addItem(.separator()) }
        }
        menu.addItem(info("Or drag the pill anywhere while it shows"))
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

    private func settingsMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.addItem(item(controller.needsSetup ? "Finish Setup…" : "Setup…", action: #selector(showSetup)))
        menu.addItem(item("How to Use Murmur…", action: #selector(showHowTo)))
        menu.addItem(submenu("Pill Position", pillPositionMenu()))
        let login = item("Launch at Login", action: #selector(toggleLaunchAtLogin))
        login.state = LoginItem.isEnabled ? .on : (LoginItem.needsApproval ? .mixed : .off)
        menu.addItem(login)
        menu.addItem(.separator())
        menu.addItem(item("Open Meeting Notes Folder", action: #selector(openMeetings)))
        menu.addItem(item("Open Compose Library Folder", action: #selector(openLibraryFolder)))
        menu.addItem(item("Open Settings File", action: #selector(openSettings)))
        menu.addItem(item("Open API Keys (.env)", action: #selector(openEnv)))
        menu.addItem(item("Reload Settings", action: #selector(reload), key: "r"))
        menu.addItem(item("Check for Updates…", action: #selector(checkForUpdates)))
        menu.addItem(item("Copy Diagnostics", action: #selector(copyDiagnostics)))
        menu.addItem(info(updateStatus()))
        menu.addItem(.separator())
        menu.addItem(info("Transcription: \(controller.transcriberName)"))
        for problem in controller.problems { menu.addItem(info("⚠️ " + problem)) }
        if let failure = controller.lastFailure { menu.addItem(info("Last issue: " + failure)) }
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

    @objc private func toggleLaunchAtLogin() {
        do {
            try LoginItem.set(!LoginItem.isEnabled)
            if LoginItem.needsApproval {
                showAlert("Approve Murmur in System Settings → General → Login Items.")
            }
        } catch {
            showAlert("Could not change Launch at Login: \(error.localizedDescription)\n\nMurmur must run from an app bundle, e.g. /Applications/Murmur.app.")
        }
    }

    @objc private func openSettings() {
        _ = try? Config.loadOrCreate(at: AppPaths.configFile)
        NSWorkspace.shared.open(AppPaths.configFile)
    }

    @objc private func openEnv() {
        let url = AppPaths.envFile
        if !FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let template = """
            # API keys for Murmur. Leave all of these empty to stay fully local and offline.
            # Transcription (engine "auto" uses the first one present) and cleanup LLM:
            GROQ_API_KEY=
            OPENAI_API_KEY=
            # Cleanup only:
            ANTHROPIC_API_KEY=
            # Only for cleanup.provider "custom", if your server needs one:
            CLEANUP_API_KEY=

            """
            FileManager.default.createFile(atPath: url.path, contents: Data(template.utf8),
                                           attributes: [.posixPermissions: 0o600])
        }
        // .env has no default app; open it as plain text.
        NSWorkspace.shared.open([url], withApplicationAt: URL(fileURLWithPath: "/System/Applications/TextEdit.app"),
                                configuration: NSWorkspace.OpenConfiguration())
    }

    @objc private func reload() {
        controller.reloadConfig()
    }


    @objc private func showSetup() {
        controller.showSetup()
    }




    private func updateStatus() -> String {
        let version = "Murmur \(controller.updater.currentVersion)"
        switch controller.updater.state {
        case .checking: return version + " · checking for updates…"
        case .upToDate: return version + " · up to date"
        case let .available(release): return version + " · \(release.tag) available"
        case let .downloading(release): return version + " · downloading \(release.tag)…"
        case let .ready(release, _): return version + " · \(release.tag) ready: Restart to Update"
        case let .installing(step): return version + " · " + step
        case let .failed(message): return "⚠️ " + message
        case .idle: return version
        }
    }

    @objc private func checkForUpdates() {
        Task { @MainActor [self] in
            await controller.updater.check(userInitiated: true)
            switch controller.updater.state {
            case let .available(release), let .downloading(release), let .ready(release, _):
                showAlert("Murmur \(release.tag) is available. It downloads in the background; choose Restart to Update in the menu when it appears.")
            case .upToDate: showAlert("You have the latest version, Murmur \(controller.updater.currentVersion).")
            case let .failed(message): showAlert(message)
            case .idle, .checking, .installing: break
            }
        }
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

    @objc private func setPillPosition(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let position = PillPosition(rawValue: raw) else { return }
        controller.pillPosition = position
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

    @objc private func removeVocabularyWord(_ sender: NSMenuItem) {
        guard let word = sender.representedObject as? String else { return }
        controller.removeVocabulary(word)
    }

    @objc private func showHowTo() {
        controller.showHowTo()
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

    @objc private func copyDiagnostics() {
        controller.copyDiagnostics()
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

    @objc private func openMeetings() {
        controller.openMeetingsFolder()
    }

    @objc private func openLibraryFolder() {
        controller.openLibraryFolder()
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
