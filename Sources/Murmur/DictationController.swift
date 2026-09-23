#if os(macOS)
import AppKit
import MurmurCore

/// Owns the whole flow: hotkey → microphone → transcription → cleanup → insertion.
@MainActor
final class DictationController {
    private(set) var config = Config()
    private var env: [String: String] = [:]
    private var machine = DictationStateMachine()
    private let hotkeys = HotkeyMonitor()
    private let recorder = AudioRecorder()
    private let inserter = TextInserter()
    private let pill = PillController()
    private var tickTimer: Timer?
    private var tapRetryTimer: Timer?
    private var jobs: [UUID: Task<Void, Never>] = [:]
    private var hotkeySpec: HotkeySpec = .modifier(.fn)

    /// Problems worth showing in the menu (bad settings, missing model, last failure).
    private(set) var problems: [String] = []
    private(set) var lastFailure: String?
    private(set) var transcriberName = "–"
    private(set) var cleanerName = "off"

    /// Called whenever something the menu shows has changed.
    var onChange: (() -> Void)?

    var enabled: Bool {
        get { UserDefaults.standard.object(forKey: "enabled") as? Bool ?? true }
        set {
            UserDefaults.standard.set(newValue, forKey: "enabled")
            if !newValue { cancelEverything() }
            onChange?()
        }
    }

    var isRecording: Bool { machine.isRecording }
    var isProcessing: Bool { !jobs.isEmpty }
    var hotkeyIsListening: Bool { hotkeys.isRunning }
    var hotkeyDescription: String { hotkeySpec.displayName }

    func start() {
        hotkeys.onEvent = { [weak self] event in self?.handle(event) }
        if Permissions.microphone == .notDetermined {
            Permissions.requestMicrophone { _ in
                Task { @MainActor [weak self] in self?.onChange?() }
            }
        }
        if !Permissions.accessibility { Permissions.promptAccessibility() }
        reloadConfig()
    }

    /// Re-reads config.json and .env and re-installs the hotkey.
    func reloadConfig() {
        cancelEverything()
        problems = []
        lastFailure = nil
        do {
            config = try Config.loadOrCreate(at: AppPaths.configFile)
        } catch {
            config = Config()
            problems.append("\(error) Using defaults.")
        }
        env = DotEnv.load(from: AppPaths.envFile)
        machine = DictationStateMachine(timing: .init(config))

        do {
            hotkeySpec = try HotkeySpec.parse(config.hotkey)
        } catch {
            hotkeySpec = .modifier(.fn)
            problems.append("Hotkey: \(error) Using fn.")
        }
        pill.model.hotkeyName = hotkeySpec.displayName

        // Build the pipeline once now so setup problems show up in the menu right away.
        do {
            let pipeline = try DictationPipeline(config: config, env: env)
            transcriberName = pipeline.transcriber.name
            cleanerName = pipeline.cleaner?.name ?? (config.cleanup.enabled ? "off (no API key)" : "off")
        } catch {
            transcriberName = "not ready"
            cleanerName = "–"
            problems.append("\(error)")
        }

        installHotkey()
        onChange?()
    }

    private func installHotkey() {
        tapRetryTimer?.invalidate()
        tapRetryTimer = nil
        if hotkeys.start(spec: hotkeySpec) { return }
        // No permission yet. Ask once, then keep trying quietly until it is granted.
        if hotkeySpec.isModifierOnly { Permissions.requestInputMonitoring() } else { Permissions.promptAccessibility() }
        tapRetryTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if self.hotkeys.start(spec: self.hotkeySpec) {
                    self.tapRetryTimer?.invalidate()
                    self.tapRetryTimer = nil
                    self.onChange?()
                }
            }
        }
    }

    // MARK: Hotkey handling

    private func handle(_ event: HotkeyEvent) {
        guard enabled else { return }
        let input: DictationInput
        switch event {
        case .hotkeyDown: input = .hotkeyDown
        case .hotkeyUp: input = .hotkeyUp
        case .otherKeyDown: input = .otherKeyDown
        case .escape: input = .escape
        }
        run(machine.handle(input, at: now))
    }

    private var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    private func run(_ actions: [DictationAction]) {
        for action in actions {
            switch action {
            case let .startRecording(mode):
                startRecording(mode)
            case let .modeChanged(mode):
                play("Pop")
                showRecordingPill(mode)
            case let .finishRecording(reason):
                finishRecording(reason)
            case let .discardRecording(reason):
                discardRecording(reason)
            case .cancelProcessing:
                cancelJobs(showMessage: true)
            }
        }
        onChange?()
    }

    private func startRecording(_ mode: RecordingMode) {
        do {
            try recorder.start()
        } catch {
            machine.reset()
            fail("\(error)")
            if Permissions.microphone == .denied { Permissions.open(.microphone) }
            return
        }
        play("Tink")
        showRecordingPill(mode)
        tickTimer?.invalidate()
        tickTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.tick() }
        }
    }

    private func tick() {
        guard machine.isRecording else { stopTicking(); return }
        let actions = machine.handle(.tick, at: now)
        if !actions.isEmpty {
            run(actions)
            return
        }
        pill.model.elapsed = machine.elapsed(at: now)
        pill.model.remaining = machine.remaining(at: now)
        pill.model.level = recorder.level
        if config.feedback.pill { pill.relayout() }
    }

    private func stopTicking() {
        tickTimer?.invalidate()
        tickTimer = nil
    }

    private func showRecordingPill(_ mode: RecordingMode) {
        guard config.feedback.pill else { return }
        pill.model.elapsed = machine.elapsed(at: now)
        pill.model.remaining = machine.remaining(at: now)
        pill.show(.recording(mode))
    }

    private func discardRecording(_ reason: DiscardReason) {
        _ = recorder.stop()
        stopTicking()
        switch reason {
        case .escape:
            play("Funk")
            flash("Cancelled")
        case .timeLimit:
            flash("Stopped at \(Int(config.handsFree.maxMinutes)) min limit, discarded")
        case .singleTap, .chord:
            refreshPill()
        }
    }

    private func finishRecording(_ reason: FinishReason) {
        let samples = recorder.stop()
        stopTicking()
        play("Pop")
        if Audio.duration(of: samples) < 0.2 {
            refreshPill()
            return
        }
        if Audio.isSilent(samples) {
            flash("No speech heard")
            return
        }
        let pipeline: DictationPipeline
        do {
            pipeline = try DictationPipeline(config: config, env: env)
        } catch {
            fail("\(error)")
            return
        }
        let context = CleanupContext(appName: NSWorkspace.shared.frontmostApplication?.localizedName)
        let insertion = config.insertion
        let limitNote = reason == .timeLimit ? "Hands-free stopped at the time limit" : nil

        let id = UUID()
        jobs[id] = Task { [weak self] in
            do {
                let result = try await pipeline.run(samples: samples, context: context)
                try Task.checkCancellation()
                guard let self else { return }
                if let problem = result.cleanupProblem { self.lastFailure = problem }
                if result.text.isEmpty {
                    self.finishJob(id, message: "No speech heard")
                    return
                }
                await self.inserter.insert(result.text, config: insertion)
                self.finishJob(id, message: limitNote)
            } catch {
                guard let self else { return }
                if Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled {
                    self.finishJob(id, message: nil)
                } else {
                    self.finishJob(id, message: nil)
                    self.fail("\(error)")
                }
            }
        }
        refreshPill()
    }

    private func finishJob(_ id: UUID, message: String?) {
        jobs[id] = nil
        if let message { flash(message) } else { refreshPill() }
        onChange?()
    }

    private func cancelJobs(showMessage: Bool) {
        guard !jobs.isEmpty else { return }
        for job in jobs.values { job.cancel() }
        jobs.removeAll()
        if showMessage {
            play("Funk")
            flash("Cancelled")
        }
    }

    private func cancelEverything() {
        if machine.isRecording {
            _ = recorder.stop()
            machine.reset()
        }
        stopTicking()
        cancelJobs(showMessage: false)
        pill.hide()
    }

    // MARK: Feedback

    /// Shows whatever is most relevant: recording beats processing beats nothing.
    private func refreshPill() {
        guard config.feedback.pill else { pill.hide(); return }
        if pill.isFlashing { return }
        if let mode = machine.mode {
            showRecordingPill(mode)
        } else if !jobs.isEmpty {
            pill.show(.processing)
        } else {
            pill.hide()
        }
    }

    private func flash(_ message: String, isError: Bool = false) {
        guard config.feedback.pill else { return }
        pill.flash(message, isError: isError, seconds: isError ? 3 : 1.4) { [weak self] in
            self?.refreshPill()
        }
    }

    private func fail(_ message: String) {
        lastFailure = message
        NSLog("Murmur: %@", message)
        play("Basso")
        flash(Self.shortError(message), isError: true)
        onChange?()
    }

    private static func shortError(_ message: String) -> String {
        let firstSentence = message.split(separator: ".", maxSplits: 1).first.map(String.init) ?? message
        return firstSentence.count > 70 ? String(firstSentence.prefix(67)) + "…" : firstSentence
    }

    private func play(_ sound: String) {
        guard config.feedback.sounds else { return }
        NSSound(named: NSSound.Name(sound))?.play()
    }
}
#endif
