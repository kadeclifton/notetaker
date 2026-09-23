#if os(macOS)
import AppKit
import SwiftUI
import MurmurCore

/// What the floating pill shows.
enum PillPhase: Equatable {
    case recording(RecordingMode)
    case processing
    case message(String, isError: Bool)
}

@MainActor
final class PillModel: ObservableObject {
    @Published var phase: PillPhase = .processing
    @Published var elapsed: TimeInterval = 0
    @Published var remaining: TimeInterval = 300
    @Published var level: Float = 0
    @Published var hotkeyName = "fn"
}

/// A small always-on-top capsule near the bottom of the screen. It never takes focus
/// or clicks, so the app you are dictating into stays active.
@MainActor
final class PillController {
    let model = PillModel()
    private let panel: NSPanel
    private let hosting: NSHostingView<PillView>
    private var flashTask: Task<Void, Never>?

    init() {
        hosting = NSHostingView(rootView: PillView(model: model))
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 220, height: 40),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: true)
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.contentView = hosting
    }

    func show(_ phase: PillPhase) {
        flashTask?.cancel()
        flashTask = nil
        model.phase = phase
        relayout()
        if !panel.isVisible { panel.orderFrontRegardless() }
        // SwiftUI may apply the new content on the next pass; size again once it has.
        Task { @MainActor [weak self] in self?.relayout() }
    }

    /// Shows a message, then runs `then` (default: hide) after `seconds`, unless something else is shown first.
    func flash(_ text: String, isError: Bool = false, seconds: TimeInterval = 1.4, then: (@MainActor () -> Void)? = nil) {
        show(.message(text, isError: isError))
        flashTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard let self, !Task.isCancelled else { return }
            self.flashTask = nil
            if let then { then() } else { self.hide() }
        }
    }

    var isFlashing: Bool { flashTask != nil }

    func hide() {
        flashTask?.cancel()
        flashTask = nil
        panel.orderOut(nil)
    }

    /// Resizes to fit the content (the text changes as the clock runs) and keeps it centered.
    func relayout() {
        let size = hosting.fittingSize
        if panel.isVisible, panel.frame.size == size { return }
        layout()
    }

    private func layout() {
        let size = hosting.fittingSize
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
        guard let frame = screen?.visibleFrame else { return }
        let origin = NSPoint(x: frame.midX - size.width / 2, y: frame.minY + 28)
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
    }
}

struct PillView: View {
    @ObservedObject var model: PillModel

    var body: some View {
        HStack(spacing: 8) {
            content
        }
        .font(.system(size: 12, weight: .medium, design: .rounded))
        .foregroundStyle(.white)
        .padding(.horizontal, 12)
        .frame(height: 30)
        .background(Capsule().fill(Color.black.opacity(0.85)))
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.15), lineWidth: 0.5))
        .padding(5)
        .fixedSize()
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .recording(.hold):
            Circle().fill(Color.red).frame(width: 8, height: 8)
            Text("Listening")
            LevelMeter(level: model.level)
            Text(Self.clock(model.elapsed)).monospacedDigit().foregroundStyle(.white.opacity(0.6))

        case .recording(.handsFree):
            Image(systemName: "lock.fill").font(.system(size: 9)).foregroundStyle(.orange)
            Text("Hands-free")
            LevelMeter(level: model.level)
            if model.remaining <= 30 {
                Text("stops in \(Int(model.remaining.rounded(.up)))s").monospacedDigit().foregroundStyle(.orange)
            } else {
                Text(Self.clock(model.elapsed)).monospacedDigit().foregroundStyle(.white.opacity(0.6))
            }
            Text("tap \(model.hotkeyName) to finish").foregroundStyle(.white.opacity(0.45))

        case .processing:
            ProgressView().controlSize(.small).tint(.white).scaleEffect(0.7).frame(width: 12, height: 12)
            Text("Transcribing")
            Text("esc to cancel").foregroundStyle(.white.opacity(0.45))

        case let .message(text, isError):
            Image(systemName: isError ? "exclamationmark.triangle.fill" : "xmark.circle.fill")
                .foregroundStyle(isError ? Color.yellow : Color.white.opacity(0.7))
            Text(text).lineLimit(1)
        }
    }

    static func clock(_ seconds: TimeInterval) -> String {
        let s = Int(seconds)
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

private struct LevelMeter: View {
    var level: Float
    private let weights: [Float] = [0.55, 0.8, 1.0, 0.8, 0.55]

    var body: some View {
        HStack(spacing: 2) {
            ForEach(weights.indices, id: \.self) { i in
                Capsule()
                    .fill(Color.white.opacity(0.9))
                    .frame(width: 2.5, height: CGFloat(3 + 11 * min(1, level * weights[i])))
            }
        }
        .frame(height: 14)
        .animation(.easeOut(duration: 0.08), value: level)
    }
}
#endif
