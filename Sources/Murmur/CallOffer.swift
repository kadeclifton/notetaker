#if os(macOS)
import AppKit
import SwiftUI
import MurmurCore

/// Watches for a call starting (another app holding the microphone while Zoom, Teams, FaceTime or a
/// browser runs) and offers to take meeting notes. Only asks; never records on its own.
@MainActor
final class CallWatcher {
    /// Whether Murmur is recording (dictation or a meeting), so its own microphone use is ignored.
    var isMurmurRecording: () -> Bool = { false }
    var onAccept: (() -> Void)?
    var onNeverAsk: (() -> Void)?

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
        guard enabled else { dismiss(); return }
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
        if murmur, panel != nil { dismiss() }
        if !busy, panel != nil { dismiss() }
        if let app = detector.update(micBusy: busy, runningApps: apps, murmurRecording: murmur) {
            offer(app)
        }
    }

    private func offer(_ app: String) {
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
        let view = CallOfferView(app: app,
                                 accept: { [weak self] in self?.dismiss(); self?.onAccept?() },
                                 later: { [weak self] in self?.dismiss() },
                                 never: { [weak self] in self?.dismiss(); self?.onNeverAsk?() })
        panel.contentView = NSHostingView(rootView: view)
        panel.setContentSize(panel.contentView?.fittingSize ?? NSSize(width: 340, height: 120))
        if let screen = NSScreen.main {
            let area = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: area.maxX - panel.frame.width - 16, y: area.maxY - panel.frame.height - 12))
        }
        panel.orderFrontRegardless()
        self.panel = panel
        closeTimer = Timer.scheduledTimer(withTimeInterval: 45, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in self?.dismiss() }
        }
    }

    func dismiss() {
        closeTimer?.invalidate()
        closeTimer = nil
        panel?.orderOut(nil)
        panel = nil
    }
}

private struct CallOfferView: View {
    let app: String
    let accept: () -> Void
    let later: () -> Void
    let never: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "waveform.and.mic").font(.title2).foregroundStyle(.purple)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Take notes for this call?").font(.headline)
                    Text("Looks like a call started in \(app). Murmur can transcribe it and write a summary when it ends. Let the others know.")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack {
                Button("Don't Ask Again", action: never).buttonStyle(.link).font(.caption)
                Spacer()
                Button("Not Now", action: later)
                Button("Take Notes", action: accept).keyboardShortcut(.defaultAction)
            }
        }
        .padding(14)
        .frame(width: 340)
    }
}
#endif
