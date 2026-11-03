#if os(macOS)
import AppKit
import SwiftUI
import MurmurCore

/// The meeting transcript as it is written, refreshed every couple of seconds.
@MainActor
final class MeetingLiveWindowController {
    let model = MeetingLiveModel()
    private var window: NSWindow?
    private var timer: Timer?

    func show(controller: DictationController) {
        model.controller = controller
        model.refresh()
        makeWindow()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if self.window?.isVisible == true { self.model.refresh() } else { self.timer?.invalidate(); self.timer = nil }
            }
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    /// Sample turns without a meeting, for the screenshot tests.
    func showPreview(turns: [MeetingSegment], elapsed: TimeInterval, pending: Int) -> NSWindow? {
        model.preview(turns: turns, elapsed: elapsed, pending: pending)
        makeWindow()
        window?.makeKeyAndOrderFront(nil)
        return window
    }

    private func makeWindow() {
        if window == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 620),
                                  styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
            window.title = "Meeting Transcript"
            window.contentView = NSHostingView(rootView: MeetingLiveView(model: model))
            window.isReleasedWhenClosed = false
            window.setFrameAutosaveName("MurmurMeetingLive")
            if window.frame.origin == .zero { window.center() }
            self.window = window
        }
    }
}

@MainActor
final class MeetingLiveModel: ObservableObject {
    weak var controller: DictationController?
    @Published private(set) var turns: [MeetingSegment] = []
    @Published private(set) var elapsed: TimeInterval = 0
    /// When the recording started, for a clock that ticks every second between refreshes.
    @Published private(set) var started: Date?
    @Published private(set) var pending = 0
    @Published private(set) var status: String?
    @Published private(set) var recording = false
    /// The finished meeting's summary to copy, once it is written.
    @Published private(set) var summary: String?
    private var summaryRead = false
    private(set) var fileURL: URL?

    func refresh() {
        guard let controller else { return }
        status = controller.meetingStatus
        if let meeting = controller.meeting {
            if meeting.fileURL != fileURL {
                summary = nil
                summaryRead = false
            }
            recording = true
            let latest = meeting.liveTranscript.turns()
            if latest != turns { turns = latest }
            elapsed = meeting.elapsed
            let start = Date().addingTimeInterval(-meeting.elapsed)
            // Only move it when it drifts, so the clock does not jitter at each refresh.
            if abs((started ?? .distantPast).timeIntervalSince(start)) > 1.5 { started = start }
            pending = meeting.piecesPending
            fileURL = meeting.fileURL
        } else {
            recording = false
            started = nil
            // Once the meeting has finished writing (no status left), read its summary once.
            if !summaryRead, status == nil, let fileURL, let text = try? String(contentsOf: fileURL, encoding: .utf8) {
                summaryRead = true
                summary = MeetingFile.parse(text, url: fileURL, fallbackDate: Date())?.shareableSummary
            }
        }
    }

    func stop() { controller?.stopMeeting() }

    /// A meeting in progress, made up: for the screenshot tests.
    func preview(turns: [MeetingSegment], elapsed: TimeInterval, pending: Int) {
        controller = nil
        self.turns = turns
        self.elapsed = elapsed
        self.pending = pending
        status = nil
        recording = true
        started = Date().addingTimeInterval(-elapsed)
    }

    func openFile() {
        if let fileURL { NSWorkspace.shared.open(fileURL) }
    }
}

private struct MeetingLiveView: View {
    @ObservedObject var model: MeetingLiveModel

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    ForEach(Array(model.turns.enumerated()), id: \.offset) { index, turn in
                        TranscriptBubble(speaker: turn.speaker.rawValue, time: MeetingTranscript.clock(turn.start), text: turn.text)
                            .id(index)
                            .transition(.opacity.combined(with: .move(edge: .bottom)))
                    }
                    if model.pending > 0 {
                        TypingIndicator().id("pending").transition(.opacity)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .animation(.spring(response: 0.35, dampingFraction: 0.85), value: model.turns.count)
                .animation(.easeOut(duration: 0.2), value: model.pending > 0)
            }
            .overlay {
                if model.turns.isEmpty { emptyState }
            }
            .safeAreaInset(edge: .top, spacing: 0) { statusBar }
            .onChange(of: model.turns.count) { _, count in
                withAnimation { proxy.scrollTo(count - 1, anchor: .bottom) }
            }
        }
        .frame(minWidth: 380, minHeight: 300)
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label(model.recording ? "Listening…" : "No meeting is being recorded",
                  systemImage: model.recording ? "waveform" : "person.2.wave.2")
        } description: {
            Text(model.recording
                 ? "Text appears here about every 30 seconds, as each piece is transcribed. Your words show on the right."
                 : "Start Meeting Notes from the menu bar or with its shortcut.")
        }
    }

    /// Recording light, clock and the actions, on a bar the transcript scrolls under.
    private var statusBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "circle.fill")
                .font(.system(size: 9))
                .foregroundStyle(model.recording ? Color.red : Color.secondary)
                .symbolEffect(.pulse, options: .repeating, isActive: model.recording && model.status == nil)
                .accessibilityHidden(true)
            if let status = model.status {
                Text(status).font(.headline)
            } else if model.recording, let started = model.started {
                Text("Recording").font(.headline)
                Text(started, style: .timer).monospacedDigit().foregroundStyle(.secondary)
            } else {
                Text("Meeting ended").font(.headline)
            }
            Spacer()
            if model.summary != nil { CopyButton(title: "Copy Summary", text: model.summary) }
            if model.fileURL != nil { Button("Open Notes") { model.openFile() } }
            if model.recording && model.status == nil {
                Button { model.stop() } label: { Label("Stop", systemImage: "stop.fill") }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
    }
}
#endif
