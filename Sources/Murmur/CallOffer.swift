#if os(macOS)
import AppKit
import SwiftUI
import MurmurCore

/// Watches for a call starting (another app holding the microphone while Zoom, Teams, FaceTime or a
/// browser runs) and offers to take meeting notes; and, while notes are being taken, for the call
/// ending, to offer to stop. Only asks; never starts or stops anything on its own.
@MainActor
final class CallWatcher {
    /// Whether Murmur is recording (dictation or a meeting), so its own microphone use is ignored.
    var isMurmurRecording: () -> Bool = { false }
    var onAccept: (() -> Void)?
    var onNeverAsk: (() -> Void)?
    /// Seconds since anyone was heard in the meeting being recorded; nil when none is.
    var secondsSinceSpeech: () -> TimeInterval? = { nil }
    var onStopMeeting: (() -> Void)?
    var onNeverOfferStop: (() -> Void)?

    private enum Offer { case start, stop }
    private var showing: Offer?
    private var endDetector = CallEndDetector()
    private var meetingTimer: Timer?

    /// Looks every 10 s while meeting notes record, if `enabled`.
    func watchMeeting(_ enabled: Bool) {
        meetingTimer?.invalidate()
        meetingTimer = nil
        endDetector = CallEndDetector()
        if showing == .stop { dismiss() }
        guard enabled else { return }
        meetingTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.checkMeeting() }
        }
    }

    private func checkMeeting() {
        guard let since = secondsSinceSpeech() else { watchMeeting(false); return }
        let others = AudioDevices.otherAppsUsingInput()
        if others == true, showing == .stop { dismiss() }
        if endDetector.update(othersUsingMic: others, sinceSpeech: since) {
            present(.stop,
                    title: "Stop meeting notes?",
                    message: others == false ? "The call seems to have ended. Murmur can stop now and write the summary."
                        : "Nobody has spoken for a few minutes. Murmur can stop now and write the summary.",
                    primary: "Stop and Summarize", secondary: "Keep Recording", never: "Don't Ask Again",
                    accept: { [weak self] in self?.onStopMeeting?() },
                    neverAction: { [weak self] in self?.onNeverOfferStop?() })
        }
    }

    private var detector = CallDetector()
    /// Only runs while a microphone is in use, to see it stay busy for a few seconds.
    private var timer: Timer?
    private var stopObservingDevices: (() -> Void)?
    private var stopObservingUse: (() -> Void)?
    private var panel: NSPanel?
    private var closeTimer: Timer?

    /// Nothing runs while no microphone is in use: macOS tells Murmur when one starts.
    func setEnabled(_ enabled: Bool) {
        timer?.invalidate()
        timer = nil
        stopObservingDevices?()
        stopObservingDevices = nil
        stopObservingUse?()
        stopObservingUse = nil
        detector = CallDetector()
        guard enabled else {
            if showing == .start { dismiss() }
            return
        }
        stopObservingDevices = AudioDevices.observeChanges { [weak self] in self?.observeMicrophones() }
        observeMicrophones()
    }

    private func observeMicrophones() {
        stopObservingUse?()
        stopObservingUse = AudioDevices.observeInUse(AudioDevices.inputs()) { [weak self] in self?.poll() }
        poll()
    }

    private func poll() {
        let murmur = isMurmurRecording()
        let busy = murmur || AudioDevices.anyInputInUse()
        // Keep looking every 2 s only while the mic is busy, until the offer is made or it goes quiet.
        if busy, timer == nil {
            timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
                Task { @MainActor [weak self] in self?.poll() }
            }
        } else if !busy {
            timer?.invalidate()
            timer = nil
        }
        var apps = NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier)
        if let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier {
            apps.removeAll { $0 == front }
            apps.insert(front, at: 0)
        }
        if showing == .start, murmur || !busy { dismiss() }
        if let app = detector.update(micBusy: busy, runningApps: apps, murmurRecording: murmur) {
            present(.start,
                    title: "Take notes for this call?",
                    message: "Looks like a call started in \(app). Murmur can transcribe it and write a summary when it ends. Let the others know.",
                    primary: "Take Notes", secondary: "Not Now", never: "Don't Ask Again",
                    accept: { [weak self] in self?.onAccept?() },
                    neverAction: { [weak self] in self?.onNeverAsk?() })
        }
    }

    private func present(_ kind: Offer, title: String, message: String, primary: String, secondary: String, never: String,
                         accept: @escaping () -> Void, neverAction: @escaping () -> Void) {
        dismiss()
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 340, height: 120),
                            styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView, .utilityWindow],
                            backing: .buffered, defer: false)
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        let view = CallOfferView(title: title, message: message, primary: primary, secondary: secondary, never: never,
                                 accept: { [weak self] in self?.dismiss(); accept() },
                                 later: { [weak self] in self?.dismiss() },
                                 neverAction: { [weak self] in self?.dismiss(); neverAction() })
        panel.contentView = NSHostingView(rootView: view)
        panel.setContentSize(panel.contentView?.fittingSize ?? NSSize(width: 340, height: 120))
        if let screen = NSScreen.main {
            let area = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: area.maxX - panel.frame.width - 16, y: area.maxY - panel.frame.height - 12))
        }
        panel.orderFrontRegardless()
        self.panel = panel
        showing = kind
        // The stop offer stays until answered: the summary is worth not missing.
        guard kind == .start else { return }
        closeTimer = Timer.scheduledTimer(withTimeInterval: 45, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in self?.dismiss() }
        }
    }

    func dismiss() {
        closeTimer?.invalidate()
        closeTimer = nil
        panel?.orderOut(nil)
        panel = nil
        showing = nil
    }
}

private struct CallOfferView: View {
    let title: String
    let message: String
    let primary: String
    let secondary: String
    let never: String
    let accept: () -> Void
    let later: () -> Void
    let neverAction: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "waveform.and.mic").font(.title2).foregroundStyle(.purple)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.headline)
                    Text(message)
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack {
                Button(never, action: neverAction).buttonStyle(.link).font(.caption)
                Spacer()
                Button(secondary, action: later)
                Button(primary, action: accept).keyboardShortcut(.defaultAction)
            }
        }
        .padding(14)
        .frame(width: 340)
    }
}
#endif
