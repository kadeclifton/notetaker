#if os(macOS)
import AppKit
import MurmurCore

/// The menu bar icon and its menu.
@MainActor
final class StatusMenu: NSObject, NSMenuDelegate {
    private let controller: DictationController
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()

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
        } else {
            image = MenuBarIcon.image(.idle)
        }
        // While a meeting records, the menu bar shows how long it has been going.
        statusItem.button?.title = controller.meeting.map { " " + MeetingTranscript.clock($0.elapsed) } ?? ""
        statusItem.button?.image = image
        statusItem.button?.imagePosition = .imageLeft
        statusItem.button?.toolTip = controller.enabled ? "Murmur: " + controller.modesDescription : "Murmur is off"
    }

    private func symbol(_ name: String) -> NSImage? {
        let image = NSImage(systemSymbolName: name, accessibilityDescription: "Murmur")
        image?.isTemplate = true
        return image
    }

    // Rebuilt every time it opens so it always reflects current state. The top level stays short:
    // what state Murmur is in, the two things you do (dictate, record a meeting), and one submenu
    // each for speech, cleanup and settings.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        controller.detectLocalLLM()

        menu.addItem(statusLine())
        let dictation = item("Dictation", action: #selector(toggleEnabled), key: "e")
        dictation.state = controller.enabled ? .on : .off
        menu.addItem(dictation)

        menu.addItem(.separator())
        addMeetingItems(to: menu)
        menu.addItem(item("Compose Library…", action: #selector(showLibrary), key: "l"))

        menu.addItem(.separator())
        if controller.usesLocalWhisper { menu.addItem(submenu("Speech Model", speechModelMenu())) }
        menu.addItem(submenu("Cleanup & Compose", writingMenu()))
        menu.addItem(submenu("Settings", settingsMenu()))

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

    private func addMeetingItems(to menu: NSMenu) {
        if let status = controller.meetingStatus {
            menu.addItem(info("Meeting Notes: \(status)"))
        } else if let meeting = controller.meeting {
            menu.addItem(item("Stop Meeting Notes · \(MeetingTranscript.clock(meeting.elapsed))", action: #selector(stopMeeting), key: "m"))
            if let warning = meeting.warnings.last { menu.addItem(info("⚠️ " + warning)) }
        } else {
            menu.addItem(item("Start Meeting Notes", action: #selector(startMeeting), key: "m"))
        }
    }

    private func speechModelMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let current = controller.currentWhisperModel
        for option in WhisperModelOption.catalog {
            var title = "\(option.title.replacingOccurrences(of: " (recommended)", with: "")) · \(option.id)"
            if case let .downloading(active, progress) = controller.downloader.state, active == option {
                title += " · downloading \(Int(progress * 100))%"
            } else if !FileManager.default.fileExists(atPath: option.localURL().path) {
                title += " · \(option.megabytes) MB download"
            }
            let choice = item(title, action: #selector(selectSpeechModel(_:)))
            choice.representedObject = option.id
            choice.state = option == current ? .on : .off
            choice.isEnabled = !controller.downloader.isDownloading
            menu.addItem(choice)
        }
        if let timing = controller.lastTiming {
            menu.addItem(.separator())
            menu.addItem(info("Last dictation: " + timing))
        }
        return menu
    }

    private func writingMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let hotkey = controller.hotkeyDescription
        if controller.hasModes {
            menu.addItem(info("Hold ⌃ with \(hotkey) to clean up, ⌃⌥ to compose; double-tap for hands-free"))
            let plain = item("Clean Up Plain \(hotkey) Too", action: #selector(togglePlainCleanup))
            plain.state = controller.plainMode == .clean ? .on : .off
            plain.isEnabled = [.dictate, .clean].contains(controller.plainMode)
            menu.addItem(plain)
            menu.addItem(.separator())
        }

        menu.addItem(info("Clean up: \(controller.cleanerName)"))
        if let model = controller.cleanupOllamaModel {
            let keep = NSMenu()
            keep.autoenablesItems = false
            for option in KeepAlive.allCases {
                let choice = item(option.title, action: #selector(setKeepAlive(_:)))
                choice.representedObject = option.rawValue
                choice.state = option == controller.keepAlive ? .on : .off
                keep.addItem(choice)
            }
            menu.addItem(submenu("Keep \(model) Loaded", keep))
        }

        menu.addItem(.separator())
        menu.addItem(info("Compose: \(controller.composerName)"))
        let choices = controller.composeModelChoices
        if !choices.isEmpty {
            let models = NSMenu()
            models.autoenablesItems = false
            let pinned = controller.composeModelSetting
            let automatic = item("Automatic: best that fits this Mac" + (controller.automaticComposeModel.map { " (\($0))" } ?? ""),
                                 action: #selector(setComposeModel(_:)))
            automatic.representedObject = ""
            automatic.state = pinned.isEmpty ? .on : .off
            models.addItem(automatic)
            models.addItem(.separator())
            for name in choices {
                let choice = item(name + (controller.composeModelSize(name).map { " · \($0)" } ?? ""),
                                  action: #selector(setComposeModel(_:)))
                choice.representedObject = name
                choice.state = name == pinned ? .on : .off
                models.addItem(choice)
            }
            menu.addItem(submenu("Compose Model", models))
        }
        if let suggestion = controller.composeSuggestion {
            let copy = item("Better for this Mac: copy \"ollama pull \(suggestion)\"", action: #selector(copyPullCommand(_:)))
            copy.representedObject = suggestion
            menu.addItem(copy)
        }

        menu.addItem(.separator())
        menu.addItem(info("Meeting summaries: \(controller.summaryName)"))
        return menu
    }

    private func settingsMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.addItem(item(controller.needsSetup ? "Finish Setup…" : "Setup…", action: #selector(showSetup)))
        let login = item("Launch at Login", action: #selector(toggleLaunchAtLogin))
        login.state = LoginItem.isEnabled ? .on : (LoginItem.needsApproval ? .mixed : .off)
        menu.addItem(login)
        menu.addItem(.separator())
        menu.addItem(item("Open Meeting Notes Folder", action: #selector(openMeetings)))
        menu.addItem(item("Open Compose Library Folder", action: #selector(openLibraryFolder)))
        menu.addItem(item("Open Settings File", action: #selector(openSettings), key: ","))
        menu.addItem(item("Open API Keys (.env)", action: #selector(openEnv)))
        menu.addItem(item("Reload Settings", action: #selector(reload), key: "r"))
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

    @objc private func selectSpeechModel(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String,
              let option = WhisperModelOption.catalog.first(where: { $0.id == id }) else { return }
        controller.selectWhisperModel(option)
    }

    @objc private func showSetup() {
        controller.showSetup()
    }

    @objc private func togglePlainCleanup() {
        controller.setPlainMode(controller.plainMode == .clean ? .dictate : .clean)
    }

    @objc private func setComposeModel(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        controller.setComposeModel(name)
    }

    @objc private func copyPullCommand(_ sender: NSMenuItem) {
        guard let model = sender.representedObject as? String else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("ollama pull \(model)", forType: .string)
    }

    @objc private func showLibrary() {
        controller.showLibrary()
    }

    @objc private func setKeepAlive(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let option = KeepAlive(rawValue: raw) else { return }
        controller.keepAlive = option
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
