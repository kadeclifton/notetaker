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
    private var hotkeySpec: HotkeySpec = .modifier(.fn)

    /// ⌃ / ⌃⌥ held with the hotkey during this recording; picks dictate, clean or compose.
    private var modeKeys: ModeKeys = .plain
    private var currentMode: DictationMode { config.modes.mode(for: modeKeys) }
    private lazy var compose: ComposeController = {
        let compose = ComposeController(inserter: inserter)
        compose.onSaved = { [weak self] in self?.library.refresh() }
        compose.onMessage = { [weak self] message in self?.flash(message) }
        compose.onTiming = { [weak self] timing in
            self?.lastTiming = timing
            self?.onChange?()
        }
        return compose
    }()
    private let library = LibraryWindowController()

    /// Transcriptions in flight. Each waits for the one before it before inserting, so text
    /// lands in the order it was dictated even when a later, shorter clip finishes first.
    private var jobs: [UUID: Task<Void, Never>] = [:]
    private var lastJob: Task<Void, Never>?

    /// Sound and pill wait until a press has lasted longer than a tap, so fn+arrow and
    /// single taps stay silent. The microphone itself starts at once so no word is clipped.
    private var recordingAnnounced = false

    /// Problems worth showing in the menu (bad settings, missing model, last failure).
    var problems: [String] { setupProblems + (pipelineProblem.map { [$0] } ?? []) }
    private var setupProblems: [String] = []
    private var pipelineProblem: String?
    private(set) var lastFailure: String?
    /// "0.4 s transcribe + 0.9 s cleanup (Ollama llama3.2:3b)", for the menu.
    private(set) var lastTiming: String?
    private(set) var transcriberName = "–"
    private(set) var cleanerName = "off"
    private(set) var composerName = "off"
    private(set) var summaryName = "off"

    /// Ollama or LM Studio, if one is running. Checked on launch, on reload and when the menu opens.
    private(set) var localLLM: LocalLLM?
    /// The Ollama model cleanup uses, if cleanup runs on Ollama. Kept loaded per `keepAlive`.
    private(set) var cleanupOllamaModel: String?

    /// How long Ollama keeps the cleanup model loaded. Set from the menu.
    var keepAlive: KeepAlive {
        get { KeepAlive(rawValue: UserDefaults.standard.string(forKey: "ollamaKeepAlive") ?? "") ?? .default }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: "ollamaKeepAlive")
            keepCleanupModelLoaded()
            onChange?()
        }
    }

    /// The meeting being recorded, if any.
    private(set) var meeting: MeetingRecorder?
    /// "Starting…", "Summarizing…": shown in the menu while a meeting starts or wraps up.
    private(set) var meetingStatus: String?

    /// Called whenever something the menu shows has changed.
    var onChange: (() -> Void)?

    /// Downloads Whisper models for the setup window and the Speech Model menu.
    let downloader = ModelDownloader()
    /// Offers and installs newer releases from GitHub.
    let updater = Updater()
    private lazy var setupWindow = SetupWindowController(controller: self)

    var enabled: Bool {
        get { UserDefaults.standard.object(forKey: "enabled") as? Bool ?? true }
        set {
            UserDefaults.standard.set(newValue, forKey: "enabled")
            if !newValue { cancelEverything() }
            onChange?()
        }
    }

    var isRecording: Bool { machine.isRecording }
    var hotkeyIsListening: Bool { hotkeys.isRunning }
    var hotkeyDescription: String { hotkeySpec.displayName }

    func start() {
        hotkeys.onInput = { [weak self] input, time in self?.handle(input, at: time) }
        hotkeys.onModifiers = { [weak self] modifiers in self?.modifiersChanged(modifiers) }
        downloader.onFinished = { [weak self] option in self?.useWhisperModel(option) }
        updater.onChange = { [weak self] in self?.onChange?() }
        if Permissions.microphone == .notDetermined {
            Permissions.requestMicrophone { _ in
                Task { @MainActor [weak self] in self?.onChange?() }
            }
        }
        if !Permissions.accessibility { Permissions.promptAccessibility() }
        reloadConfig()
        if needsSetup { showSetup() }
    }

    /// Re-reads config.json and .env and re-installs the hotkey.
    func reloadConfig() {
        cancelEverything()
        setupProblems = []
        lastFailure = nil
        do {
            config = try Config.loadOrCreate(at: AppPaths.configFile)
        } catch {
            config = Config()
            setupProblems.append("\(error) Using defaults.")
        }
        env = DotEnv.load(from: AppPaths.envFile)
        machine = DictationStateMachine(timing: .init(config))

        do {
            hotkeySpec = try HotkeySpec.parse(config.hotkey)
        } catch {
            hotkeySpec = .modifier(.fn)
            setupProblems.append("Hotkey: \(error) Using fn.")
        }
        pill.model.hotkeyName = hotkeySpec.displayName

        refreshModels()
        // Load the Whisper model now, so the first dictation does not wait for it.
        if let server = (try? config.makeTranscriber(env: env) as? WhisperServerTranscriber)?.server {
            Task.detached { try? await server.ensureRunning() }
        }
        detectLocalLLM()
        installHotkey()
        updater.configure(config.updates)
        onChange?()
    }

    /// Looks for Ollama / LM Studio again (they may have been started since).
    func detectLocalLLM() {
        Task { [weak self] in
            let found = await LocalLLM.detect()
            guard let self, found != self.localLLM else { return }
            self.localLLM = found
            self.refreshModels()
            self.onChange?()
        }
    }

    /// Builds the pipeline once so the menu shows what will be used and any setup problem.
    private func refreshModels() {
        pipelineProblem = nil
        let previousOllamaModel = cleanupOllamaModel
        cleanupOllamaModel = nil
        do {
            let pipeline = try DictationPipeline(config: config, env: env, local: localLLM)
            transcriberName = pipeline.transcriber.name
            cleanerName = pipeline.cleaner?.name
                ?? (config.cleanup.enabled ? "off (no API key or small local model)" : "off")
            cleanupOllamaModel = Self.ollamaModel(of: pipeline.cleaner)
        } catch {
            transcriberName = "not ready"
            cleanerName = "–"
            pipelineProblem = "\(error)"
        }
        do {
            composerName = try config.makeComposer(env: env, local: localLLM)?.name ?? "off (no API key or local model)"
        } catch {
            composerName = "not ready: \(error)"
        }
        let m = config.meeting
        let summary = m.summarize
            ? try? config.makeChatModel(provider: m.summaryProvider, model: m.summaryModel, baseURL: config.cleanup.baseURL,
                                        env: env, local: localLLM, purpose: .summary)
            : nil
        summaryName = summary?.name ?? (m.summarize ? "off (no API key or local model)" : "off")
        // A newly chosen cleanup model: load it now so the first dictation does not wait.
        if cleanupOllamaModel != previousOllamaModel { keepCleanupModelLoaded() }
    }

    private static func ollamaModel(of cleaner: TextCleaner?) -> String? {
        ((cleaner as? LLMCleaner)?.chat as? OllamaChat)?.model
    }

    /// Loads the cleanup model (if needed) and restarts its keep-loaded timer.
    private func keepCleanupModelLoaded() {
        guard let model = cleanupOllamaModel else { return }
        let keepAlive = self.keepAlive
        Task.detached { await LocalLLM.keepLoaded(model: model, for: keepAlive) }
    }

    // MARK: Meetings

    func startMeeting() {
        guard meeting == nil, meetingStatus == nil else { return }
        meetingStatus = "Starting…"
        onChange?()
        Task { [weak self] in
            guard let self else { return }
            // A local model may have been started since launch.
            self.localLLM = await LocalLLM.detect()
            self.refreshModels()
            do {
                let language = self.config.transcription.language.lowercased()
                let vocabulary = self.config.transcription.vocabulary.filter { !$0.isEmpty }
                let m = self.config.meeting
                let setup = MeetingRecorder.Setup(
                    config: m,
                    transcriber: try self.config.makeTranscriber(env: self.env),
                    language: language.isEmpty || language == "auto" ? nil : language,
                    prompt: vocabulary.isEmpty ? nil : vocabulary.joined(separator: ", ") + ".",
                    summarizer: m.summarize
                        ? try? self.config.makeChatModel(provider: m.summaryProvider, model: m.summaryModel,
                                                         baseURL: self.config.cleanup.baseURL, env: self.env, local: self.localLLM,
                                                         purpose: .summary)
                        : nil)
                let recorder = try await MeetingRecorder.start(setup)
                recorder.onChange = { [weak self] in self?.onChange?() }
                recorder.onTimeLimit = { [weak self] in self?.stopMeeting() }
                self.meeting = recorder
                self.play("Tink")
                self.flash("Meeting notes are recording")
            } catch {
                self.fail("Could not start meeting notes: \(error)")
                if Permissions.microphone == .denied { Permissions.open(.microphone) }
            }
            self.meetingStatus = nil
            self.onChange?()
        }
    }

    func stopMeeting(summarize: Bool = true, then: (@MainActor () -> Void)? = nil) {
        guard let meeting, meetingStatus == nil else {
            // Nothing to stop, or it is already finishing (the transcript is saved as it goes).
            then?()
            return
        }
        meetingStatus = "Finishing…"
        play("Pop")
        onChange?()
        Task { [weak self] in
            let url = await meeting.stop(summarize: summarize) { message in
                self?.meetingStatus = message
                if self?.config.feedback.pill == true { self?.pill.show(.message(message, isError: false)) }
                self?.onChange?()
            }
            guard let self else { return }
            self.meeting = nil
            self.meetingStatus = nil
            self.flash("Meeting notes saved")
            self.onChange?()
            if let then {
                then()
            } else {
                NSWorkspace.shared.open(url)
            }
        }
    }

    // MARK: Setup

    /// True when dictation goes through whisper.cpp on this Mac (no Groq/OpenAI key in use).
    var usesLocalWhisper: Bool {
        switch config.transcription.engine {
        case .local: return true
        case .groq, .openai: return false
        case .auto: return HostedAPI.groq.key(in: env) == nil && HostedAPI.openAI.key(in: env) == nil
        }
    }

    var whisperInstalled: Bool {
        let configured = config.transcription.whisperCpp.binary
        return WhisperCppTranscriber.locateServer(configuredCli: configured) != nil
            || WhisperCppTranscriber.locateBinary(configured: configured) != nil
    }

    var whisperModelPath: String { AppPaths.resolve(config.transcription.whisperCpp.model) }
    var whisperModelInstalled: Bool { FileManager.default.fileExists(atPath: whisperModelPath) }
    var currentWhisperModel: WhisperModelOption? { WhisperModelOption.matching(path: config.transcription.whisperCpp.model) }

    /// Anything missing that stops dictation from working.
    var needsSetup: Bool {
        (usesLocalWhisper && (!whisperInstalled || !whisperModelInstalled))
            || Permissions.microphone != .authorized
            || !Permissions.accessibility
            || !hotkeyIsListening
    }

    func showSetup() {
        setupWindow.show()
    }

    /// Switches dictation to a catalog model, downloading it first if needed.
    func selectWhisperModel(_ option: WhisperModelOption) {
        if FileManager.default.fileExists(atPath: option.localURL().path) {
            useWhisperModel(option)
        } else {
            downloader.download(option)
            onChange?()
        }
    }

    /// Points the settings file at a downloaded model and reloads.
    private func useWhisperModel(_ option: WhisperModelOption) {
        do {
            _ = try Config.loadOrCreate(at: AppPaths.configFile)
            if try ConfigFileEdit.setWhisperModel(option.configPath, in: AppPaths.configFile) {
                reloadConfig()
                flash("Speech model: \(option.title)")
            } else {
                fail("Downloaded \(option.fileName). Set transcription.whisperCpp.model to \"\(option.configPath)\" in the settings file.")
            }
        } catch {
            fail("Could not update the settings file: \(error)")
        }
    }

    /// The modes only apply to a modifier-only hotkey like fn; a shortcut hotkey is always plain.
    var hasModes: Bool { hotkeySpec.isModifierOnly }

    /// "fn dictate · fn⌃ clean up · fn⌃⌥ compose", for the menu.
    var modesDescription: String {
        guard hasModes else { return "hold \(hotkeyDescription) to \(config.modes.hotkey.title.lowercased())" }
        return ModeKeys.allCases.map { keys in
            "\(keys.label(hotkey: hotkeyDescription)) \(config.modes.mode(for: keys).title.lowercased())"
        }.joined(separator: " · ")
    }

    var plainMode: DictationMode { config.modes.hotkey }

    /// Sets what the hotkey does on its own (the menu offers dictate or clean).
    func setPlainMode(_ mode: DictationMode) {
        editSettings("modes", "hotkey", json: ConfigFileEdit.quoted(mode.rawValue)) { $0.modes.hotkey == mode }
    }

    /// The compose model pinned in the settings, or "" for automatic.
    var composeModelSetting: String { config.compose.model }

    /// Local models that can write, for the Compose Model menu. Empty without Ollama or LM Studio,
    /// or when compose uses a hosted API.
    var composeModelChoices: [String] {
        guard let local = localLLM, [.auto, .local].contains(config.compose.provider),
              config.compose.provider == .local || composerName.hasPrefix(local.server) else { return [] }
        return local.models.filter { name in
            let lower = name.lowercased()
            return !LocalLLM.nonChatMarkers.contains { lower.contains($0) }
        }
    }

    /// What Automatic picks on this Mac.
    var automaticComposeModel: String? { localLLM?.pickModel(for: .compose) }

    func composeModelSize(_ name: String) -> String? { localLLM?.sizeDescription(of: name) }

    /// A better model to pull for Compose, when Ollama is in use and this Mac could run one.
    var composeSuggestion: String? {
        guard let local = localLLM, local.isOllama, !composeModelChoices.isEmpty else { return nil }
        let suggested = LocalLLM.suggestedComposeModel()
        return local.models.contains(suggested) ? nil : suggested
    }

    func setComposeModel(_ model: String) {
        editSettings("compose", "model", json: ConfigFileEdit.quoted(model)) { $0.compose.model == model }
    }

    /// Changes one setting in the settings file (comments kept) and reloads.
    private func editSettings(_ section: String, _ key: String, json: String, verify: (Config) -> Bool) {
        do {
            _ = try Config.loadOrCreate(at: AppPaths.configFile)
            if try ConfigFileEdit.set(section, key, json: json, in: AppPaths.configFile, verify: verify) {
                reloadConfig()
            } else {
                fail("Could not change \(section).\(key) in the settings file. Edit it by hand, then Reload Settings.")
            }
        } catch {
            fail("Could not update the settings file: \(error)")
        }
    }

    func openLibraryFolder() {
        let folder = LibraryStore(config: config.compose).folder
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        NSWorkspace.shared.open(folder)
    }

    func showLibrary() {
        library.show(store: LibraryStore(config: config.compose))
    }

    /// After an update, System Settings can show Murmur switched on while the grant belongs to the
    /// previous build. Clearing Murmur's entries lets macOS ask again for this build.
    func resetPermissions() {
        let bundleID = Bundle.main.bundleIdentifier ?? "com.github.kadeclifton.murmur"
        for service in ["Accessibility", "ListenEvent", "ScreenCapture"] {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
            process.arguments = ["reset", service, bundleID]
            try? process.run()
            process.waitUntilExit()
        }
        Permissions.promptAccessibility()
        Permissions.requestInputMonitoring()
    }

    /// Input Monitoring only takes effect in a freshly started process.
    func relaunch() {
        let path = Bundle.main.bundleURL.path
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "sleep 1; /usr/bin/open \"$0\"", path]
        try? process.run()
        NSApp.terminate(nil)
    }

    func openMeetingsFolder() {
        let folder = URL(fileURLWithPath: AppPaths.expandTilde(config.meeting.folder), isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        NSWorkspace.shared.open(folder)
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

    private func handle(_ input: DictationInput, at time: TimeInterval) {
        guard enabled else { return }
        run(machine.handle(input, at: time))
    }

    private var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    private func run(_ actions: [DictationAction]) {
        for action in actions {
            switch action {
            case .startRecording:
                startRecording()
            case .modeChanged:
                announceRecording()
            case let .finishRecording(reason):
                finishRecording(reason)
            case let .discardRecording(reason):
                discardRecording(reason)
            case .cancelProcessing:
                cancelJobs(showMessage: true)
                if compose.isShowing { compose.dismiss() }
            }
        }
        onChange?()
    }

    /// ⌃ or ⌃⌥ joined the hotkey: this recording becomes clean or compose. Never goes back down.
    private func modifiersChanged(_ modifiers: ShortcutModifiers) {
        guard machine.isRecording, hasModes else { return }
        let keys = ModeKeys(extraModifiers: modifiers)
        guard keys > modeKeys else { return }
        let before = currentMode
        modeKeys = keys
        if currentMode != before { applyMode() }
    }

    /// Mode-specific recording settings: the pill's tag, and Compose's longer time limit.
    private func applyMode() {
        let mode = currentMode
        let minutes = mode == .compose ? config.compose.maxMinutes : config.handsFree.maxMinutes
        machine.timing.maxDuration = max(10, minutes * 60)
        pill.model.mode = mode
        if recordingAnnounced, let recording = machine.mode { showRecordingPill(recording) }
        if mode == .compose { warmComposeModel() }
    }

    /// Starts loading a local compose model while you are still talking, so writing starts
    /// as soon as the transcript is ready rather than after a 10-20 s model load.
    private func warmComposeModel() {
        guard let chat = (try? config.makeComposer(env: env, local: localLLM))?.chat as? OllamaChat else { return }
        let model = chat.model
        Task.detached { await LocalLLM.keepLoaded(model: model, for: .fiveMinutes) }
    }

    private func startRecording() {
        recordingAnnounced = false
        modeKeys = .plain
        applyMode()
        recorder.start { [weak self] error in
            guard let self, let error else { return }
            if self.machine.isRecording {
                self.machine.reset()
                self.stopTicking()
            }
            self.fail("\(error)")
            if Permissions.microphone == .denied { Permissions.open(.microphone) }
        }
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
        if !recordingAnnounced, case .holding = machine.state, machine.elapsed(at: now) >= machine.timing.tapMax {
            announceRecording()
        }
        guard recordingAnnounced else { return }
        pill.model.elapsed = machine.elapsed(at: now)
        pill.model.remaining = machine.remaining(at: now)
        pill.model.level = recorder.level
        if config.feedback.pill { pill.relayout() }
    }

    private func stopTicking() {
        tickTimer?.invalidate()
        tickTimer = nil
    }

    /// First sign the user gets that we are recording: a sound and the pill.
    private func announceRecording() {
        guard let mode = machine.mode else { return }
        if !recordingAnnounced { play("Tink") }
        recordingAnnounced = true
        showRecordingPill(mode)
    }

    private func showRecordingPill(_ mode: RecordingMode) {
        guard config.feedback.pill else { return }
        pill.model.elapsed = machine.elapsed(at: now)
        pill.model.remaining = machine.remaining(at: now)
        pill.show(.recording(mode))
    }

    private func discardRecording(_ reason: DiscardReason) {
        let wasAnnounced = recordingAnnounced
        recordingAnnounced = false
        stopTicking()
        recorder.stop { _ in }
        switch reason {
        case .escape where wasAnnounced:
            play("Funk")
            flash("Cancelled")
        case .timeLimit:
            flash("Stopped at \(Int(machine.timing.maxDuration / 60)) min limit, discarded")
        case .escape, .singleTap, .chord:
            refreshPill()
        }
    }

    private func finishRecording(_ reason: FinishReason) {
        recordingAnnounced = false
        stopTicking()
        play("Pop")
        let mode = currentMode
        let target = NSWorkspace.shared.frontmostApplication
        // Compose adapts to the page too (Gmail vs. ChatGPT in the same browser).
        let context = CleanupContext(appName: target?.localizedName,
                                     windowTitle: mode == .compose ? FocusedWindow.title(of: target) : nil)
        recorder.stop { [weak self] samples in
            self?.transcribe(samples, reason: reason, context: context, mode: mode, target: target)
        }
        if config.feedback.pill {
            if mode == .compose { pill.hide() } else { pill.show(.processing) }
        }
    }

    private func transcribe(_ samples: [Float], reason: FinishReason, context: CleanupContext,
                            mode: DictationMode, target: NSRunningApplication?) {
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
            pipeline = try DictationPipeline(config: config, env: env, local: localLLM, mode: mode)
        } catch {
            fail("\(error)")
            return
        }
        if mode == .compose {
            let composer: Composer?
            do {
                composer = try config.makeComposer(env: env, local: localLLM)
            } catch {
                composer = nil
                lastFailure = "Compose: \(error)"
            }
            compose.start(samples: samples,
                          setup: .init(pipeline: pipeline, composer: composer, store: LibraryStore(config: config.compose),
                                       insertion: config.insertion, defaultStyle: config.compose.defaultStyle),
                          context: context, target: target)
            refreshPill()
            return
        }
        let insertion = config.insertion
        let limitNote = reason == .timeLimit ? "Hands-free stopped at the time limit" : nil
        let previous = lastJob

        let id = UUID()
        let job = Task { [weak self] in
            do {
                let result = try await pipeline.run(samples: samples, context: context)
                // Insert in dictation order: wait for the job before this one to finish.
                await previous?.value
                try Task.checkCancellation()
                guard let self else { return }
                if let problem = result.cleanupProblem { self.lastFailure = problem }
                self.lastTiming = Self.describeTiming(result, cleaner: pipeline.cleaner?.name)
                // Each cleanup request resets Ollama's timer to its 5-minute default; set ours again.
                if result.cleanupSeconds != nil { self.keepCleanupModelLoaded() }
                if result.text.isEmpty {
                    self.finishJob(id, message: "No speech heard")
                    return
                }
                await self.inserter.insert(result.text, config: insertion)
                self.finishJob(id, message: limitNote)
            } catch {
                guard let self else { return }
                self.finishJob(id, message: nil)
                let cancelled = Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled
                if !cancelled { self.fail("\(error)") }
            }
        }
        jobs[id] = job
        lastJob = job
        refreshPill()
    }

    private func finishJob(_ id: UUID, message: String?) {
        jobs[id] = nil
        if jobs.isEmpty { lastJob = nil }
        if let message { flash(message) } else { refreshPill() }
        onChange?()
    }

    private func cancelJobs(showMessage: Bool) {
        guard !jobs.isEmpty else { return }
        for job in jobs.values { job.cancel() }
        jobs.removeAll()
        lastJob = nil
        if showMessage {
            play("Funk")
            flash("Cancelled")
        }
    }

    private func cancelEverything() {
        if machine.isRecording {
            recorder.stop { _ in }
            machine.reset()
        }
        recordingAnnounced = false
        stopTicking()
        cancelJobs(showMessage: false)
        compose.dismiss()
        pill.hide()
    }

    // MARK: Feedback

    /// Shows whatever is most relevant: recording beats processing beats nothing.
    private func refreshPill() {
        guard config.feedback.pill else { pill.hide(); return }
        if pill.isFlashing { return }
        if recordingAnnounced, let mode = machine.mode {
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

    private static func describeTiming(_ result: PipelineResult, cleaner: String?) -> String {
        var text = String(format: "%.1f s transcribe", result.transcribeSeconds)
        if let cleanup = result.cleanupSeconds {
            text += String(format: " + %.1f s cleanup", cleanup)
            if let cleaner { text += " (\(cleaner))" }
        }
        return text
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
