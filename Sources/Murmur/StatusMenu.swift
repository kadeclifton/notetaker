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
        let symbol: String
        if controller.meeting != nil {
            symbol = "record.circle"
        } else if !controller.enabled {
            symbol = "waveform.slash"
        } else if controller.isRecording {
            symbol = "waveform.circle.fill"
        } else if !controller.hotkeyIsListening || !controller.problems.isEmpty {
            symbol = "exclamationmark.triangle"
        } else {
            symbol = "waveform"
        }
        // While a meeting records, the menu bar shows how long it has been going.
        statusItem.button?.title = controller.meeting.map { " " + MeetingTranscript.clock($0.elapsed) } ?? ""
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Murmur")
        image?.isTemplate = true
        statusItem.button?.image = image
        statusItem.button?.imagePosition = .imageLeft
        statusItem.button?.toolTip = controller.enabled ? "Murmur: hold \(controller.hotkeyDescription) to dictate" : "Murmur is off"
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

        menu.addItem(.separator())
        if controller.usesLocalWhisper { menu.addItem(submenu("Speech Model", speechModelMenu())) }
        menu.addItem(submenu("Cleanup", cleanupMenu()))
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
        return info("Ready · hold \(controller.hotkeyDescription) to talk, double-tap for hands-free")
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

    private func cleanupMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let toggle = item("Fix Punctuation & Remove Filler Words", action: #selector(toggleCleanup))
        toggle.state = controller.cleanupEnabled ? .on : .off
        menu.addItem(toggle)
        if controller.cleanupEnabled {
            menu.addItem(info("Using: \(controller.cleanerName)"))
        }
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

    @objc private func toggleCleanup() {
        controller.setCleanupEnabled(!controller.cleanupEnabled)
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
