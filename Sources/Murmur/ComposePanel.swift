#if os(macOS)
import AppKit
import SwiftUI
import MurmurCore

/// One Compose run: what was said, what is being written, and how.
@MainActor
final class ComposeSession: ObservableObject {
    enum Phase: Equatable {
        case transcribing
        case writing
        case done
        case failed(String)
    }

    @Published var phase: Phase = .transcribing
    @Published var transcript = ""
    @Published var text = ""
    @Published var style: ComposeStyle = .auto
    /// Why this style: "you said so", "for Slack".
    @Published var styleNote = ""
    @Published var modelName = ""
    @Published var showTranscript = false
    @Published var editing = false
    /// "Written in 8.2 s".
    @Published var timing: String?

    let context: CleanupContext
    /// The app to insert into: the one in front when the recording ended.
    let target: NSRunningApplication?
    var entry: LibraryEntry?

    init(context: CleanupContext, target: NSRunningApplication?) {
        self.context = context
        self.target = target
    }

    var isBusy: Bool { phase == .transcribing || phase == .writing }
    /// What Insert and Copy use: the writing, or what was said if nothing got written.
    var output: String { text.isEmpty ? transcript : text }
}

/// Runs Compose after a hotkey+⌃⌥ recording: transcribes, streams the writing into a preview
/// panel, and inserts it only when asked. Every piece is saved to the library as it goes.
@MainActor
final class ComposeController: NSObject, NSWindowDelegate {
    struct Setup {
        var pipeline: DictationPipeline
        var composer: Composer?
        var store: LibraryStore
        var insertion: InsertionConfig
        var defaultStyle: ComposeStyle
    }

    private let inserter: TextInserter
    private var panel: NSPanel?
    private(set) var session: ComposeSession?
    private var setup: Setup?
    private var task: Task<Void, Never>?

    /// Called after something was saved to the library.
    var onSaved: (() -> Void)?
    /// Short messages for the pill ("Copied").
    var onMessage: ((String) -> Void)?
    /// "2.1 s transcribe + 9.4 s compose (Ollama qwen3:30b)", for the menu.
    var onTiming: ((String) -> Void)?
    /// Text that was inserted (with how) or copied (nil), for the Recent list.
    var onDelivered: ((String, TextInserter.Outcome?) -> Void)?

    init(inserter: TextInserter) {
        self.inserter = inserter
    }

    var isShowing: Bool { panel?.isVisible ?? false }

    func start(samples: [Float], setup: Setup, context: CleanupContext, target: NSRunningApplication?) {
        dismiss()
        let session = ComposeSession(context: context, target: target)
        session.modelName = setup.composer?.name ?? "no model"
        self.session = session
        self.setup = setup
        show(session)
        task = Task { [weak self] in
            do {
                let result = try await setup.pipeline.run(samples: samples, context: context)
                guard let self, self.session === session, !Task.isCancelled else { return }
                guard !result.transcript.isEmpty else {
                    session.phase = .failed("No speech heard.")
                    return
                }
                session.transcript = result.transcript
                // Keep the ramble even if the writing fails or the panel is closed.
                self.save(session)
                await self.write(session, chosen: nil, temperature: 0.3, transcribeSeconds: result.transcribeSeconds)
            } catch {
                guard let self, self.session === session, !Self.isCancellation(error) else { return }
                session.phase = .failed("\(error)")
            }
        }
    }

    private func write(_ session: ComposeSession, chosen: ComposeStyle?, temperature: Double,
                       transcribeSeconds: TimeInterval? = nil) async {
        guard let setup else { return }
        let (style, source) = ComposeStyle.resolve(chosen: chosen, transcript: session.transcript,
                                                   context: session.context, defaultStyle: setup.defaultStyle)
        session.style = style
        session.styleNote = Self.describe(source)
        session.editing = false
        session.timing = nil
        guard let composer = setup.composer else {
            session.phase = .failed(ComposeError.noModel.description)
            return
        }
        session.phase = .writing
        session.text = ""
        let started = Date()
        do {
            for try await text in composer.write(session.transcript, style: style, context: session.context,
                                                 temperature: temperature) {
                guard self.session === session else { return }
                session.text = text
            }
            guard self.session === session, !Task.isCancelled else { return }
            let seconds = Date().timeIntervalSince(started)
            session.phase = .done
            session.timing = String(format: "Written in %.1f s", seconds)
            save(session)
            var timing = String(format: "%.1f s compose (%@)", seconds, composer.name)
            if let transcribeSeconds { timing = String(format: "%.1f s transcribe + ", transcribeSeconds) + timing }
            onTiming?(timing)
        } catch {
            guard self.session === session, !Self.isCancellation(error) else { return }
            let reason = (error as? URLError)?.code == .timedOut
                ? "The model took longer than compose.timeoutSeconds. A smaller Compose Model (menu bar) is quicker."
                : "\(error)"
            session.phase = .failed(reason)
        }
    }

    // MARK: Panel actions

    func retry() { rewrite(chosen: session?.style, temperature: 0.8) }

    func restyle(_ style: ComposeStyle) { rewrite(chosen: style, temperature: 0.3) }

    private func rewrite(chosen: ComposeStyle?, temperature: Double) {
        guard let session, !session.transcript.isEmpty else { return }
        task?.cancel()
        task = Task { [weak self] in await self?.write(session, chosen: chosen, temperature: temperature) }
    }

    func insert() {
        guard let session, let setup else { return }
        let text = session.output
        guard !text.isEmpty else { return }
        close(saving: true)
        Task { [inserter, weak self] in
            // Hand focus back to the app the text is for, then paste as usual.
            _ = session.target?.activate()
            try? await Task.sleep(nanoseconds: 250_000_000)
            let outcome = await inserter.insert(text, config: setup.insertion)
            self?.onDelivered?(text, outcome)
        }
    }

    func copy() {
        guard let session else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(session.output, forType: .string)
        onDelivered?(session.output, nil)
        close(saving: true)
        onMessage?("Copied")
    }

    /// Esc, Close, or a new recording: stop writing and put the panel away. Nothing is lost:
    /// what was said (and anything written) is already in the library.
    func dismiss() {
        close(saving: true)
    }

    private func close(saving: Bool) {
        task?.cancel()
        task = nil
        if saving, let session { save(session) }
        session = nil
        setup = nil
        panel?.orderOut(nil)
    }

    func windowWillClose(_ notification: Notification) {
        close(saving: true)
    }

    // MARK: Library

    private func save(_ session: ComposeSession) {
        guard let setup, !session.transcript.isEmpty else { return }
        var entry = session.entry ?? LibraryEntry(style: session.style, app: session.context.appName,
                                                  text: "", transcript: session.transcript)
        entry.style = session.style
        entry.transcript = session.transcript
        // Half-written text is not worth keeping; finished (and edited) text is.
        if session.phase == .done {
            entry.text = session.text
            entry.model = session.modelName
        }
        guard entry != session.entry else { return }
        do {
            session.entry = try setup.store.save(entry)
            onSaved?()
        } catch {
            NSLog("Murmur: could not save to the library: %@", "\(error)")
        }
    }

    // MARK: Window

    private func show(_ session: ComposeSession) {
        let view = ComposeView(session: session, controller: self)
        if panel == nil {
            let panel = KeyablePanel(contentRect: NSRect(x: 0, y: 0, width: 640, height: 460),
                                     styleMask: [.titled, .closable, .resizable, .fullSizeContentView, .nonactivatingPanel],
                                     backing: .buffered, defer: false)
            panel.titleVisibility = .hidden
            panel.titlebarAppearsTransparent = true
            panel.isMovableByWindowBackground = true
            panel.isFloatingPanel = true
            panel.level = .floating
            panel.hidesOnDeactivate = false
            panel.isReleasedWhenClosed = false
            panel.becomesKeyOnlyIfNeeded = false
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.minSize = NSSize(width: 480, height: 320)
            panel.delegate = self
            self.panel = panel
        }
        guard let panel else { return }
        panel.contentView = NSHostingView(rootView: view)
        if !panel.isVisible {
            let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
            if let frame = screen?.visibleFrame {
                let size = panel.frame.size
                panel.setFrameOrigin(NSPoint(x: frame.midX - size.width / 2, y: frame.midY - size.height / 2 + frame.height * 0.08))
            }
        }
        // Takes the keyboard (⏎, Esc) without activating Murmur, so the app underneath stays in front.
        panel.makeKeyAndOrderFront(nil)
    }

    private static func describe(_ source: ComposeStyle.Source) -> String {
        switch source {
        case .chosen: return ""
        case .spoken: return "you asked for it"
        case let .app(name): return "for \(name)"
        case .setting: return "your default"
        case .none: return ""
        }
    }

    private static func isCancellation(_ error: Error) -> Bool {
        Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled
    }
}

/// A non-activating panel that can still take the keyboard.
private final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

struct ComposeView: View {
    @ObservedObject var session: ComposeSession
    let controller: ComposeController

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            styles
            content
            if !session.transcript.isEmpty {
                DisclosureGroup("What I said", isExpanded: $session.showTranscript) {
                    ScrollView {
                        Text(session.transcript)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 110)
                }
                .font(.callout)
                .foregroundStyle(.secondary)
            }
            Divider()
            buttons
        }
        .padding(.horizontal, 20)
        .padding(.top, 28)
        .padding(.bottom, 16)
        .frame(minWidth: 480, minHeight: 320)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkles").foregroundStyle(.purple)
            Text("Compose").font(.headline)
            Spacer()
            switch session.phase {
            case .transcribing:
                ProgressView().controlSize(.small)
                Text("Transcribing…").foregroundStyle(.secondary)
            case .writing:
                ProgressView().controlSize(.small)
                Text("Writing with \(session.modelName)…").foregroundStyle(.secondary).lineLimit(1)
            case .done:
                Text([session.timing, session.modelName].compactMap { $0 }.joined(separator: " · "))
                    .foregroundStyle(.secondary).lineLimit(1)
            case .failed:
                EmptyView()
            }
        }
        .font(.callout)
    }

    private var styles: some View {
        HStack(spacing: 6) {
            ForEach(ComposeStyle.allCases, id: \.self) { style in
                Button(style.title) { controller.restyle(style) }
                    .buttonStyle(.bordered)
                    .tint(style == session.style ? .purple : nil)
                    .controlSize(.small)
                    .disabled(session.transcript.isEmpty)
            }
            if !session.styleNote.isEmpty {
                Text(session.styleNote).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private var content: some View {
        if case let .failed(message) = session.phase {
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
        }
        if session.editing {
            TextEditor(text: $session.text)
                .font(.body)
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
        } else {
            ScrollView {
                Text(Self.rendered(shownText))
                    .font(.body)
                    .foregroundStyle(session.text.isEmpty ? Color.secondary : Color.primary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: .infinity)
        }
    }

    private var shownText: String {
        if !session.text.isEmpty { return session.text }
        switch session.phase {
        case .transcribing: return "Listening back to what you said…"
        case .writing: return "Thinking it through…"
        case .done, .failed: return session.transcript
        }
    }

    private var buttons: some View {
        HStack {
            Button("Try Again") { controller.retry() }
                .disabled(session.isBusy || session.transcript.isEmpty)
            Button(session.editing ? "Done Editing" : "Edit") { session.editing.toggle() }
                .disabled(session.isBusy)
            Spacer()
            Text("Saved in your Compose Library").font(.caption).foregroundStyle(.tertiary)
            Button("Close") { controller.dismiss() }
                .keyboardShortcut(.cancelAction)
            Button("Copy") { controller.copy() }
                .disabled(session.output.isEmpty)
            Button("Insert") { controller.insert() }
                .keyboardShortcut(.defaultAction)
                .disabled(session.isBusy || session.output.isEmpty)
        }
    }

    /// Bold, italics and links show as such; line breaks and list markers stay as written.
    static func rendered(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
    }
}
#endif

#if os(macOS)
/// The title of an app's focused window, through Accessibility. Tells Gmail from ChatGPT when both
/// are "Google Chrome".
enum FocusedWindow {
    static func title(of app: NSRunningApplication?) -> String? {
        guard let pid = app?.processIdentifier, Permissions.accessibility else { return nil }
        let element = AXUIElementCreateApplication(pid)
        // A hung app must not hold up the recording.
        AXUIElementSetMessagingTimeout(element, 0.25)
        var window: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXFocusedWindowAttribute as CFString, &window) == .success,
              let window, CFGetTypeID(window) == AXUIElementGetTypeID() else { return nil }
        var title: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window as! AXUIElement, kAXTitleAttribute as CFString, &title) == .success else {
            return nil
        }
        return (title as? String).flatMap { $0.isEmpty ? nil : $0 }
    }
}
#endif
