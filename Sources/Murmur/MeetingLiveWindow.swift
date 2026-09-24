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
}

@MainActor
final class MeetingLiveModel: ObservableObject {
    weak var controller: DictationController?
    @Published private(set) var turns: [MeetingSegment] = []
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var pending = 0
    @Published private(set) var status: String?
    @Published private(set) var recording = false
    private(set) var fileURL: URL?

    func refresh() {
        guard let controller else { return }
        status = controller.meetingStatus
        if let meeting = controller.meeting {
            recording = true
            let latest = meeting.liveTranscript.turns()
            if latest != turns { turns = latest }
            elapsed = meeting.elapsed
            pending = meeting.piecesPending
            fileURL = meeting.fileURL
        } else {
            recording = false
        }
    }

    func stop() { controller?.stopMeeting() }

    func openFile() {
        if let fileURL { NSWorkspace.shared.open(fileURL) }
    }
}

private struct MeetingLiveView: View {
    @ObservedObject var model: MeetingLiveModel

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Circle().fill(model.recording ? Color.red : Color.secondary).frame(width: 9, height: 9)
                Text(header).font(.headline)
                Spacer()
                if model.fileURL != nil { Button("Open Notes") { model.openFile() } }
                if model.recording && model.status == nil { Button("Stop") { model.stop() } }
            }
            .padding(12)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        if model.turns.isEmpty {
                            Text(model.recording
                                 ? "Listening… text appears here about every 30 seconds, as each piece is transcribed."
                                 : "No meeting is being recorded.")
                                .foregroundStyle(.secondary)
                        }
                        ForEach(Array(model.turns.enumerated()), id: \.offset) { index, turn in
                            VStack(alignment: .leading, spacing: 2) {
                                Text("\(turn.speaker.rawValue) · \(MeetingTranscript.clock(turn.start))")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(turn.speaker == .me ? Color.purple : Color.secondary)
                                Text(turn.text).textSelection(.enabled)
                            }
                            .id(index)
                        }
                        if model.pending > 0 {
                            Text("Transcribing…").font(.caption).foregroundStyle(.secondary).id("pending")
                        }
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: model.turns.count) { _, count in
                    withAnimation { proxy.scrollTo(count - 1, anchor: .bottom) }
                }
            }
        }
        .frame(minWidth: 380, minHeight: 300)
    }

    private var header: String {
        if let status = model.status { return status }
        return model.recording ? "Recording · \(MeetingTranscript.clock(model.elapsed))" : "Meeting ended"
    }
}
#endif
