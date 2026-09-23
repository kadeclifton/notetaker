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
        model.modelInstalled = controller.whisperModelInstalled
        model.currentModel = controller.currentWhisperModel
        model.microphone = Permissions.microphone == .authorized
        model.accessibility = Permissions.accessibility
        model.inputMonitoring = Permissions.inputMonitoring && controller.hotkeyIsListening
        model.hotkey = controller.hotkeyDescription
        model.cleanup = controller.cleanerName
        model.localLLM = controller.localLLM.map { "\($0.server): \($0.models.joined(separator: ", "))" }
    }
}

@MainActor
final class SetupModel: ObservableObject {
    @Published var usesLocalWhisper = true
    @Published var whisperInstalled = false
    @Published var modelInstalled = false
    @Published var currentModel: WhisperModelOption?
    @Published var microphone = false
    @Published var accessibility = false
    @Published var inputMonitoring = false
    @Published var hotkey = "fn"
    @Published var cleanup = "off"
    @Published var localLLM: String?

    var ready: Bool {
        (!usesLocalWhisper || (whisperInstalled && modelInstalled)) && microphone && accessibility && inputMonitoring
    }
}

@MainActor
struct SetupActions {
    let controller: DictationController

    func copyBrewCommand() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("brew install whisper-cpp", forType: .string)
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
        Permissions.requestInputMonitoring()
        Permissions.open(.inputMonitoring)
    }

    func resetPermissions() { controller.resetPermissions() }
    func relaunch() { controller.relaunch() }
    func openSettingsFile() { NSWorkspace.shared.open(AppPaths.configFile) }
}

struct SetupView: View {
    @ObservedObject var model: SetupModel
    @ObservedObject var downloader: ModelDownloader
    let actions: SetupActions
    @State private var choice: WhisperModelOption = .small

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Hold \(model.hotkey), talk, let go: your words appear wherever you're typing.")
                .font(.headline)

            if model.usesLocalWhisper {
                step(done: model.whisperInstalled, title: "Install whisper.cpp",
                     detail: "The speech recognizer. In Terminal, run  brew install whisper-cpp") {
                    Button("Copy Command") { actions.copyBrewCommand() }
                    Button("Check Again") { actions.recheck() }
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
                Text("Optional: punctuation and filler-word cleanup").font(.subheadline.weight(.semibold))
                Text("Cleanup: \(model.cleanup)").font(.caption).foregroundStyle(.secondary)
                if let local = model.localLLM {
                    Text("Found \(local)").font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("Install Ollama (brew install ollama, then ollama serve) and run  ollama pull qwen3:4b . 16 GB Macs only; skip it on 8 GB.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 0)
            HStack {
                if model.ready {
                    Label("Ready. Hold \(model.hotkey) and talk.", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                }
                Spacer()
                Button("Open Settings File") { actions.openSettingsFile() }
            }
        }
        .padding(24)
        .frame(width: 560)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear { if let current = model.currentModel { choice = current } }
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
                    Text("\(option.title): \(option.detail) · \(option.megabytes) MB").tag(option)
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
#endif
