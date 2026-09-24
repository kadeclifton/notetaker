#if os(macOS)
import AppKit
import SwiftUI
import MurmurCore

/// The first-run checklist: whisper.cpp, a speech model, and the three permissions, each with a
/// button that fixes it. Opens at launch when something is missing, and from the menu any time.
@MainActor
final class SetupWindowController {
    private let controller: DictationController
    private var window: NSWindow?
    private var refreshTimer: Timer?
    private let model = SetupModel()

    init(controller: DictationController) {
        self.controller = controller
    }

    func show() {
        refresh()
        if window == nil {
            let view = SetupView(model: model, downloader: controller.downloader, actions: SetupActions(controller: controller))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 600),
                                  styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "Set up Murmur"
            window.contentView = NSHostingView(rootView: view)
            window.isReleasedWhenClosed = false
            window.center()
            self.window = window
        }
        // Murmur has no Dock icon; bring the window forward explicitly.
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refresh() }
        }
    }

    /// Permissions change in System Settings, not in Murmur, so poll while the window is open.
    private func refresh() {
        guard window?.isVisible ?? true else {
            refreshTimer?.invalidate()
            refreshTimer = nil
            return
        }
        model.usesLocalWhisper = controller.usesLocalWhisper
        model.whisperInstalled = controller.whisperInstalled
        model.homebrewInstalled = Homebrew.isInstalled
        model.modelInstalled = controller.whisperModelInstalled
        model.currentModel = controller.currentWhisperModel
        model.microphone = Permissions.microphone == .authorized
        model.accessibility = Permissions.accessibility
        model.inputMonitoring = Permissions.inputMonitoring && controller.hotkeyIsListening
        model.hotkey = controller.hotkeyDescription
        model.cleanup = controller.cleanerName
        model.compose = controller.composerName
        model.localLLM = controller.localLLM.map { "\($0.server): \($0.models.joined(separator: ", "))" }
        model.launchAtLogin = LoginItem.isEnabled
        if model.ready && !UserDefaults.standard.bool(forKey: "setupCompleted") {
            // First time everything works: start at login from now on (a switch below turns it
            // off), and show the cheat sheet once.
            UserDefaults.standard.set(true, forKey: "setupCompleted")
            try? LoginItem.set(true)
            model.launchAtLogin = LoginItem.isEnabled
            controller.showHowToOnce()
        }
    }
}

@MainActor
final class SetupModel: ObservableObject {
    @Published var usesLocalWhisper = true
    @Published var whisperInstalled = false
    @Published var homebrewInstalled = true
    @Published var modelInstalled = false
    @Published var currentModel: WhisperModelOption?
    @Published var microphone = false
    @Published var accessibility = false
    @Published var inputMonitoring = false
    @Published var hotkey = "fn"
    @Published var cleanup = "off"
    @Published var compose = "off"
    @Published var localLLM: String?
    @Published var launchAtLogin = false

    var ready: Bool {
        (!usesLocalWhisper || (whisperInstalled && modelInstalled)) && microphone && accessibility && inputMonitoring
    }
}

@MainActor
struct SetupActions {
    let controller: DictationController

    /// Without Homebrew: install it, make `brew` work in new Terminal windows, then install whisper.cpp,
    /// all in one paste. With Homebrew: just whisper.cpp.
    func copyInstallCommand(homebrewInstalled: Bool) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(homebrewInstalled ? Homebrew.whisperCommand : Homebrew.everythingCommand, forType: .string)
    }

    /// Opens a normal Terminal window that runs the install by itself: a .command file is what
    /// Terminal opens and runs on a double-click, so no copy and paste and no extra permission.
    func installInTerminal(homebrewInstalled: Bool) {
        let command = homebrewInstalled ? Homebrew.whisperCommand : Homebrew.everythingCommand
        let what = homebrewInstalled ? "whisper.cpp" : "Homebrew, then whisper.cpp"
        let script = """
        #!/bin/zsh
        clear
        echo "Murmur is installing \(what)."
        echo "If it asks for your Mac password, type it (nothing shows as you type) and press Return."
        echo
        \(command)
        result=$?
        echo
        if [ $result -eq 0 ]; then
          echo "Done. Switch back to Murmur: its setup window ticks this step by itself."
        else
          echo "That didn't finish (see above). Close this window and click Install in Murmur to try again."
        fi
        echo
        read -k 1 -s "?Press any key to close this window."
        """
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("Install for Murmur.command")
        do {
            try Data(script.utf8).write(to: file, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
            NSWorkspace.shared.open(file)
        } catch {
            // Fall back to the manual way.
            copyInstallCommand(homebrewInstalled: homebrewInstalled)
            NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app"))
        }
    }

    func openHomebrewSite() {
        NSWorkspace.shared.open(URL(string: "https://brew.sh")!)
    }

    func recheck() { controller.reloadConfig() }
    func download(_ option: WhisperModelOption) { controller.selectWhisperModel(option) }
    func cancelDownload() { controller.downloader.cancel() }

    func allowMicrophone() {
        if Permissions.microphone == .notDetermined {
            Permissions.requestMicrophone { _ in }
        } else {
            Permissions.open(.microphone)
        }
    }

    func allowAccessibility() {
        Permissions.promptAccessibility()
        Permissions.open(.accessibility)
    }

    func allowInputMonitoring() {
        // Switching this on makes macOS offer "Quit & Reopen", and the reopen doesn't always happen
        // for a menu bar app. Make sure Murmur comes back (and shows this window) either way.
        Permissions.reopenIfQuit()
        Permissions.requestInputMonitoring()
        Permissions.open(.inputMonitoring)
    }

    func resetPermissions() { controller.resetPermissions() }

    func setLaunchAtLogin(_ enabled: Bool) {
        try? LoginItem.set(enabled)
    }

    func showHowTo() { controller.showHowTo() }
    func relaunch() { controller.relaunch() }
    func openSettingsFile() { NSWorkspace.shared.open(AppPaths.configFile) }
}

struct SetupView: View {
    @ObservedObject var model: SetupModel
    @ObservedObject var downloader: ModelDownloader
    let actions: SetupActions
    @State private var choice: WhisperModelOption = .recommended()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Hold \(model.hotkey), talk, let go: your words appear wherever you're typing.")
                    .font(.headline)
                Text("Add ⌃ to clean it up. Add ⌃⌥ to compose: talk it through, get it back written.")
                    .font(.callout).foregroundStyle(.secondary)
            }

            if model.usesLocalWhisper {
                if !model.whisperInstalled && !model.homebrewInstalled {
                    step(done: false, title: "Install Homebrew and whisper.cpp",
                         detail: "whisper.cpp, the speech recognizer, comes from Homebrew, which this Mac doesn't have yet. "
                            + "Click Install: a Terminal window opens and runs it. Type your Mac password when asked "
                            + "(nothing shows as you type) and press Return. It may install Apple's developer tools "
                            + "first; allow 10 to 15 minutes. This step ticks itself when it's done.") {
                        Button("Install in Terminal") { actions.installInTerminal(homebrewInstalled: false) }
                        Button("Copy Command") { actions.copyInstallCommand(homebrewInstalled: false) }
                        Button("About Homebrew") { actions.openHomebrewSite() }
                    }
                } else {
                    step(done: model.whisperInstalled, title: "Install whisper.cpp",
                         detail: "The speech recognizer. Click Install: a Terminal window opens and runs  "
                            + Homebrew.whisperCommand + "  (a minute or two). This step ticks itself when it's done.") {
                        Button("Install in Terminal") { actions.installInTerminal(homebrewInstalled: true) }
                        Button("Copy Command") { actions.copyInstallCommand(homebrewInstalled: true) }
                    }
                }
                modelStep
            }

            step(done: model.microphone, title: "Allow the microphone",
                 detail: "Murmur only listens while you hold the key or during Meeting Notes.") {
                Button("Allow…") { actions.allowMicrophone() }
            }
            step(done: model.accessibility, title: "Allow Accessibility",
                 detail: "Lets Murmur paste the text into the app you're using.") {
                Button("Open Settings…") { actions.allowAccessibility() }
            }
            step(done: model.inputMonitoring, title: "Allow Input Monitoring",
                 detail: "Lets Murmur notice the \(model.hotkey) key. Quit and reopen Murmur after allowing it.") {
                Button("Open Settings…") { actions.allowInputMonitoring() }
                Button("Restart Murmur") { actions.relaunch() }
            }

            if !(model.accessibility && model.inputMonitoring) {
                Text("Already switched on in System Settings but still not ticked here? After an update the old switch no longer applies.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Reset Murmur's Permissions and Ask Again") { actions.resetPermissions() }
                    .controlSize(.small)
            }

            Divider()
            VStack(alignment: .leading, spacing: 4) {
                Text("Optional: a local model for ⌃ cleanup and ⌃⌥ compose").font(.subheadline.weight(.semibold))
                Text("Cleanup: \(model.cleanup) · Compose: \(model.compose)").font(.caption).foregroundStyle(.secondary)
                if let local = model.localLLM {
                    Text("Found \(local)").font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("Install Ollama (brew install ollama, then ollama serve) and run  ollama pull qwen3:4b  for cleanup and  ollama pull \(LocalLLM.suggestedComposeModel())  for compose. On an 8 GB Mac, qwen3:4b alone.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 0)
            if model.ready {
                Toggle("Start Murmur when I log in", isOn: Binding(
                    get: { model.launchAtLogin },
                    set: { enabled in
                        actions.setLaunchAtLogin(enabled)
                        model.launchAtLogin = enabled
                    }))
            }
            HStack {
                if model.ready {
                    Label("Ready. Hold \(model.hotkey) and talk.", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    Button("How to Use…") { actions.showHowTo() }
                }
                Spacer()
                Button("Open Settings File") { actions.openSettingsFile() }
            }
        }
        .padding(24)
        .frame(width: 560)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear { if model.modelInstalled, let current = model.currentModel { choice = current } }
    }

    @ViewBuilder
    private var modelStep: some View {
        step(done: model.modelInstalled && !downloader.isDownloading, title: "Download a speech model",
             detail: model.modelInstalled
                ? "Using \(model.currentModel?.title ?? "your configured model"). Switch any time from the menu: Speech Model."
                : "Stays on this Mac. Nothing you say is uploaded.") {
            EmptyView()
        }
        VStack(alignment: .leading, spacing: 8) {
            Picker("", selection: $choice) {
                ForEach(WhisperModelOption.catalog) { option in
                    Text("\(option.title): \(option.detail) · \(option.megabytes) MB"
                         + (option == WhisperModelOption.recommended() ? " · recommended for this Mac" : "")).tag(option)
                }
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()
            .disabled(downloader.isDownloading)

            switch downloader.state {
            case let .downloading(option, progress):
                HStack {
                    ProgressView(value: progress)
                    Text("\(Int(progress * 100))% of \(option.megabytes) MB").font(.caption).monospacedDigit()
                    Button("Cancel") { actions.cancelDownload() }
                }
            case let .failed(message):
                Text(message).font(.caption).foregroundStyle(.red)
                Button("Try Again") { actions.download(choice) }
            case .idle:
                Button(model.modelInstalled && choice == model.currentModel ? "Downloaded" : "Download and Use") {
                    actions.download(choice)
                }
                .disabled(model.modelInstalled && choice == model.currentModel)
            }
        }
        .padding(.leading, 30)
    }

    private func step<Buttons: View>(done: Bool, title: String, detail: String,
                                     @ViewBuilder buttons: () -> Buttons) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: done ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(done ? Color.green : Color.secondary)
                .font(.title3)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if !done {
                    HStack { buttons() }.controlSize(.small)
                }
            }
        }
    }
}
/// Homebrew, which provides whisper.cpp.
enum Homebrew {
    /// Apple Silicon installs to /opt/homebrew; older setups used /usr/local.
    static var isInstalled: Bool {
        ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"].contains { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static let whisperCommand = "brew install whisper-cpp"

    /// Homebrew's official installer, then `brew` on the PATH for this and future Terminal windows,
    /// then whisper.cpp. Each step runs only if the one before it worked.
    static let everythingCommand =
        #"/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)" && "#
        + #"(grep -q 'brew shellenv' ~/.zprofile 2>/dev/null || echo 'eval "$(/opt/homebrew/bin/brew shellenv)"' >> ~/.zprofile) && "#
        + #"eval "$(/opt/homebrew/bin/brew shellenv)" && brew install whisper-cpp"#
}
#endif
