#if os(macOS)
import AppKit
import SwiftUI
import MurmurCore

/// What the floating pill shows.
enum PillPhase: Equatable {
    case recording(RecordingMode)
    /// "Transcribing", then "Cleaning up".
    case processing(String)
    case message(String, isError: Bool)
}

@MainActor
final class PillModel: ObservableObject {
    @Published var phase: PillPhase = .processing("Transcribing")
    @Published var elapsed: TimeInterval = 0
    @Published var remaining: TimeInterval = 300
    @Published var level: Float = 0
    @Published var hotkeyName = "fn"
    /// What this recording will become; changes when ⌃ or ⌃⌥ joins the hotkey.
    @Published var mode: DictationMode = .dictate
}

/// A small always-on-top capsule, under the menu bar by default. It never takes focus, so the app
/// you are dictating into stays active, but it can be dragged anywhere; the spot is remembered.
@MainActor
final class PillController {
    let model = PillModel()
    private let panel: NSPanel
    private let hosting: NSHostingView<PillView>
    private var flashTask: Task<Void, Never>?
    /// True while Murmur itself moves the pill, so only the user's drags are saved.
    private var positioning = false
    private var moveObserver: NSObjectProtocol?

    static let positionKey = "pillPosition"
    static let customXKey = "pillCustomX"
    static let customYKey = "pillCustomY"

    /// Where the pill goes. Set from the menu; dragging it sets `.custom`.
    var position: PillPosition {
        get { PillPosition(rawValue: UserDefaults.standard.string(forKey: Self.positionKey) ?? "") ?? .default }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: Self.positionKey)
            if panel.isVisible { layout() }
        }
    }

    private var customAnchor: CGPoint? {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: Self.customXKey) != nil else { return nil }
        return CGPoint(x: defaults.double(forKey: Self.customXKey), y: defaults.double(forKey: Self.customYKey))
    }

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
        // Takes the mouse only so it can be dragged; a borderless panel never becomes key, so the
        // text field you are dictating into keeps the keyboard.
        panel.ignoresMouseEvents = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        // The pill has no buttons, so a see-through layer on top takes every click and turns it into a drag.
        let container = NSView(frame: hosting.frame)
        hosting.autoresizingMask = [.width, .height]
        hosting.frame = container.bounds
        container.addSubview(hosting)
        let grip = DragOverlay(frame: container.bounds)
        grip.autoresizingMask = [.width, .height]
        grip.toolTip = "Drag to move"
        container.addSubview(grip)
        panel.contentView = container
        moveObserver = NotificationCenter.default.addObserver(forName: NSWindow.didMoveNotification, object: panel,
                                                              queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.userMoved() }
        }
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

    /// Resizes to fit the content (the text changes as the clock runs) and keeps it in place.
    func relayout() {
        let size = hosting.fittingSize
        if panel.isVisible, panel.frame.size == size { return }
        layout()
    }

    private func layout() {
        let size = hosting.fittingSize
        guard let frame = screen()?.visibleFrame else { return }
        let origin = PillPlacement.origin(for: position, size: size, in: frame, custom: customAnchor)
        positioning = true
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
        positioning = false
    }

    /// The screen with the mouse on it: where you are working.
    private func screen() -> NSScreen? {
        NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
    }

    /// A drag: remember the spot, as a fraction of the screen so it carries over to other displays.
    private func userMoved() {
        guard !positioning, let frame = (panel.screen ?? screen())?.visibleFrame else { return }
        let anchor = PillPlacement.anchor(of: panel.frame, in: frame)
        let defaults = UserDefaults.standard
        defaults.set(Double(anchor.x), forKey: Self.customXKey)
        defaults.set(Double(anchor.y), forKey: Self.customYKey)
        defaults.set(PillPosition.custom.rawValue, forKey: Self.positionKey)
    }
}

/// Turns a press anywhere on the pill into a window drag, even though Murmur is not the active app.
private final class DragOverlay: NSView {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }
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
            ModeTag(mode: model.mode)
            LevelMeter(level: model.level)
            Text(Self.clock(model.elapsed)).monospacedDigit().foregroundStyle(.white.opacity(0.6))

        case .recording(.handsFree):
            Image(systemName: "lock.fill").font(.system(size: 9)).foregroundStyle(.orange)
            Text("Hands-free")
            ModeTag(mode: model.mode)
            LevelMeter(level: model.level)
            if model.remaining <= 30 {
                Text("stops in \(Int(model.remaining.rounded(.up)))s").monospacedDigit().foregroundStyle(.orange)
            } else {
                Text(Self.clock(model.elapsed)).monospacedDigit().foregroundStyle(.white.opacity(0.6))
            }
            Text("tap \(model.hotkeyName) to finish").foregroundStyle(.white.opacity(0.45))

        case let .processing(step):
            ProgressView().controlSize(.small).tint(.white).scaleEffect(0.7).frame(width: 12, height: 12)
            Text(step)
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

/// "Clean Up" or "Compose" next to "Listening"; nothing for plain dictation.
private struct ModeTag: View {
    var mode: DictationMode

    static func color(_ mode: DictationMode) -> Color {
        switch mode {
        case .compose: return Color.purple.opacity(0.85)
        case .edit: return Color.orange.opacity(0.85)
        case .dictate, .clean: return Color.blue.opacity(0.75)
        }
    }

    var body: some View {
        switch mode {
        case .dictate:
            EmptyView()
        case .clean, .compose, .edit:
            Text(mode.title)
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Capsule().fill(Self.color(mode)))
        }
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
