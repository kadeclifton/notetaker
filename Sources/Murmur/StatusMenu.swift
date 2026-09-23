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

    // Rebuilt every time it opens so it always reflects current state.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        controller.detectLocalLLM()

        let toggle = item(controller.enabled ? "Murmur is On" : "Murmur is Off", action: #selector(toggleEnabled), key: "e")
        toggle.state = controller.enabled ? .on : .off
        menu.addItem(toggle)

        menu.addItem(info("Hold \(controller.hotkeyDescription) to talk · double-tap for hands-free · Esc cancels"))
        menu.addItem(info("Transcription: \(controller.transcriberName)"))
        menu.addItem(info("Cleanup: \(controller.cleanerName)"))
        if let local = controller.localLLM {
            menu.addItem(info("Local models (\(local.server)): \(local.models.joined(separator: ", "))"))
        }

        menu.addItem(.separator())
        if let status = controller.meetingStatus {
            menu.addItem(info("Meeting notes: \(status)"))
        } else if let meeting = controller.meeting {
            menu.addItem(item("Stop Meeting Notes (\(MeetingTranscript.clock(meeting.elapsed)))", action: #selector(stopMeeting), key: "m"))
            for warning in meeting.warnings.suffix(2) { menu.addItem(info("⚠️ " + warning)) }
        } else {
            menu.addItem(item("Start Meeting Notes", action: #selector(startMeeting), key: "m"))
        }
        menu.addItem(info("Meeting summaries: \(controller.summaryName)"))
        menu.addItem(item("Open Meeting Notes Folder", action: #selector(openMeetings)))
        for problem in controller.problems { menu.addItem(info("⚠️ " + problem)) }
        if let failure = controller.lastFailure { menu.addItem(info("Last issue: " + failure)) }

        let missing = permissionItems()
        if !missing.isEmpty {
            menu.addItem(.separator())
            for item in missing { menu.addItem(item) }
        }

        menu.addItem(.separator())
        let login = item("Launch at Login", action: #selector(toggleLaunchAtLogin))
        login.state = LoginItem.isEnabled ? .on : (LoginItem.needsApproval ? .mixed : .off)
        menu.addItem(login)
        menu.addItem(item("Open Settings File", action: #selector(openSettings), key: ","))
        menu.addItem(item("Open .env (API keys)", action: #selector(openEnv)))
        menu.addItem(item("Reload Settings", action: #selector(reload), key: "r"))
        menu.addItem(.separator())
        menu.addItem(item("Quit Murmur", action: #selector(quit), key: "q"))
    }

    private func permissionItems() -> [NSMenuItem] {
        var items: [NSMenuItem] = []
        if !Permissions.inputMonitoring || !controller.hotkeyIsListening {
            items.append(item("⚠️ Grant Input Monitoring (for the hotkey)…", action: #selector(openInputMonitoring)))
        }
        if !Permissions.accessibility {
            items.append(item("⚠️ Grant Accessibility (for pasting)…", action: #selector(openAccessibility)))
        }
        if Permissions.microphone != .authorized {
            items.append(item("⚠️ Grant Microphone…", action: #selector(openMicrophone)))
        }
        if controller.config.meeting.captureSystemAudio && !Permissions.screenRecording {
            items.append(item("Grant Screen & System Audio Recording (for meeting audio)…", action: #selector(openScreenRecording)))
        }
        return items
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

    @objc private func openInputMonitoring() {
        Permissions.requestInputMonitoring()
        Permissions.open(.inputMonitoring)
    }

    @objc private func openAccessibility() {
        Permissions.promptAccessibility()
        Permissions.open(.accessibility)
    }

    @objc private func openMicrophone() {
        if Permissions.microphone == .notDetermined {
            Permissions.requestMicrophone { _ in }
        } else {
            Permissions.open(.microphone)
        }
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

    @objc private func openScreenRecording() {
        Permissions.requestScreenRecording()
        Permissions.open(.screenRecording)
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
