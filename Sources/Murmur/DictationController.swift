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
    private(set) var summaryName = "off"

    /// Ollama or LM Studio, if one is running. Checked on launch, on reload and when the menu opens.
    private(set) var localLLM: LocalLLM?

    /// The meeting being recorded, if any.
    private(set) var meeting: MeetingRecorder?
    /// "Starting…", "Summarizing…": shown in the menu while a meeting starts or wraps up.
    private(set) var meetingStatus: String?

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
    var hotkeyIsListening: Bool { hotkeys.isRunning }
    var hotkeyDescription: String { hotkeySpec.displayName }

    func start() {
        hotkeys.onInput = { [weak self] input, time in self?.handle(input, at: time) }
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
        do {
            let pipeline = try DictationPipeline(config: config, env: env, local: localLLM)
            transcriberName = pipeline.transcriber.name
            cleanerName = pipeline.cleaner?.name
                ?? (config.cleanup.enabled ? "off (no API key or small local model)" : "off")
        } catch {
            transcriberName = "not ready"
            cleanerName = "–"
            pipelineProblem = "\(error)"
        }
        let m = config.meeting
        let summary = m.summarize
            ? try? config.makeChatModel(provider: m.summaryProvider, model: m.summaryModel, baseURL: config.cleanup.baseURL,
                                        env: env, local: localLLM, purpose: .summary)
            : nil
        summaryName = summary?.name ?? (m.summarize ? "off (no API key or local model)" : "off")
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
            }
        }
        onChange?()
    }

    private func startRecording() {
        recordingAnnounced = false
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
            flash("Stopped at \(Int(config.handsFree.maxMinutes)) min limit, discarded")
        case .escape, .singleTap, .chord:
            refreshPill()
        }
    }

    private func finishRecording(_ reason: FinishReason) {
        recordingAnnounced = false
        stopTicking()
        play("Pop")
        let context = CleanupContext(appName: NSWorkspace.shared.frontmostApplication?.localizedName)
        recorder.stop { [weak self] samples in
            self?.transcribe(samples, reason: reason, context: context)
        }
        if config.feedback.pill { pill.show(.processing) }
    }

    private func transcribe(_ samples: [Float], reason: FinishReason, context: CleanupContext) {
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
            pipeline = try DictationPipeline(config: config, env: env, local: localLLM)
        } catch {
            fail("\(error)")
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
