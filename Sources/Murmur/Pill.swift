#if os(macOS)
import AppKit
import QuartzCore
import SwiftUI
import MurmurCore

/// What the floating pill shows.
enum PillPhase: Equatable {
    case recording(RecordingMode)
    /// "Transcribing", then "Cleaning up"; Esc cancels.
    case processing(String)
    /// Something Murmur is busy with that Esc does not cancel ("Writing the summary…").
    case status(String)
    case message(String, isError: Bool)
    /// A dictation went in: "42 words".
    case done(String)

    /// Changes only when the pill's layout changes, not with the text in it; drives the transitions.
    var kind: String {
        switch self {
        case .recording(.hold): return "hold"
        case .recording(.handsFree): return "handsFree"
        case .processing, .status: return "busy"
        case .message: return "message"
        case .done: return "done"
        }
    }
}

@MainActor
final class PillModel: ObservableObject {
    /// How many recent loudness readings the waveform shows: 1.2 s at the recording tick of 20 a second.
    static let historyCount = 24

    @Published var phase: PillPhase = .processing("Transcribing")
    @Published var elapsed: TimeInterval = 0
    @Published var remaining: TimeInterval = 300
    /// Recent loudness, roughly 0...1. Each reading also scrolls the waveform.
    @Published var level: Float = 0 {
        didSet { levels = Array(levels.dropFirst()) + [level] }
    }
    @Published private(set) var levels = [Float](repeating: 0, count: PillModel.historyCount)
    @Published var hotkeyName = "fn"
    /// What this recording will become; changes when ⌃ or ⌃⌥ joins the hotkey.
    @Published var mode: DictationMode = .dictate
    /// Words transcribed so far in a long dictation (Apple's engine shows them within seconds).
    @Published var liveText = ""
    /// False while the pill fades in or out.
    @Published var visible = false

    func clearLevels() {
        levels = [Float](repeating: 0, count: Self.historyCount)
    }
}

/// A small always-on-top capsule, under the menu bar by default. It never takes focus, so the app
/// you are dictating into stays active, but it can be dragged anywhere; the spot is remembered.
/// It fades in, glides to its new size as its content changes, and fades out.
@MainActor
final class PillController {
    let model = PillModel()
    private let panel: NSPanel
    private let hosting: NSHostingView<PillView>
    private var flashTask: Task<Void, Never>?
    private var hideTask: Task<Void, Never>?
    /// True while Murmur itself moves the pill, so only the user's drags are saved.
    private var positioning = false
    /// Resize animations still running; their moves are not the user's either.
    private var frameAnimations = 0
    /// The size the pill was last laid out at, so the 20-a-second ticks only resize when it changes.
    private var laidOutSize: CGSize?
    private var moveObserver: NSObjectProtocol?

    static let positionKey = "pillPosition"
    static let customXKey = "pillCustomX"
    static let customYKey = "pillCustomY"
    /// Long enough for SwiftUI's fade and spring to finish before the panel goes away.
    private static let fadeSeconds = 0.2

    /// Where the pill goes. Set from the menu; dragging it sets `.custom`.
    var position: PillPosition {
        get { PillPosition(rawValue: UserDefaults.standard.string(forKey: Self.positionKey) ?? "") ?? .default }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: Self.positionKey)
            if panel.isVisible { layout(animated: false) }
        }
    }

    private var customAnchor: CGPoint? {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: Self.customXKey) != nil else { return nil }
        return CGPoint(x: defaults.double(forKey: Self.customXKey), y: defaults.double(forKey: Self.customYKey))
    }

    private var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    init() {
        hosting = NSHostingView(rootView: PillView(model: model))
        // Report the pill's size without pinning the view to it, so the panel can glide between sizes.
        hosting.sizingOptions = [.intrinsicContentSize]
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 220, height: 48),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: true)
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        // The capsule draws its own shadow; a window shadow would lag behind the resize animation.
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
        hideTask?.cancel()
        hideTask = nil
        let appearing = !panel.isVisible
        if phase != model.phase || appearing { announce(phase) }
        if appearing, case .recording = phase { model.clearLevels() }
        model.phase = phase
        if appearing {
            layout(animated: false)
            panel.orderFrontRegardless()
        } else {
            relayout()
        }
        // Set after the panel is on screen, so SwiftUI animates the pill in rather than drawing it already there.
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.model.visible = true
            self.relayout()
        }
        // A phase change cross-fades; once the old content is gone the pill can shrink to the new one.
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 350_000_000)
            self?.relayout()
        }
    }

    /// Shows a message, then runs `then` (default: hide) after `seconds`, unless something else is shown first.
    func flash(_ text: String, isError: Bool = false, seconds: TimeInterval = 1.4, then: (@MainActor () -> Void)? = nil) {
        flash(.message(text, isError: isError), seconds: seconds, then: then)
    }

    /// The check mark after a dictation goes in, briefly.
    func done(_ text: String, seconds: TimeInterval = 0.9, then: (@MainActor () -> Void)? = nil) {
        flash(.done(text), seconds: seconds, then: then)
    }

    private func flash(_ phase: PillPhase, seconds: TimeInterval, then: (@MainActor () -> Void)?) {
        show(phase)
        flashTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard let self, !Task.isCancelled else { return }
            self.flashTask = nil
            if let then { then() } else { self.hide() }
        }
    }

    var isFlashing: Bool { flashTask != nil }

    /// The pill never takes VoiceOver focus, so VoiceOver users hear what it shows instead.
    private func announce(_ phase: PillPhase) {
        guard NSWorkspace.shared.isVoiceOverEnabled else { return }
        let text: String
        switch phase {
        case .recording(.hold): text = model.mode == .dictate ? "Listening" : "Listening, \(model.mode.title)"
        case .recording(.handsFree): text = "Hands-free, listening. Tap \(model.hotkeyName) to finish."
        case let .processing(step): text = step
        case let .status(message): text = message
        case let .message(message, _): text = message
        case let .done(message): text = "Done, \(message)"
        }
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                             userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }

    func hide() {
        flashTask?.cancel()
        flashTask = nil
        guard panel.isVisible, hideTask == nil else { return }
        model.visible = false
        hideTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.fadeSeconds * 1_000_000_000))
            guard let self, !Task.isCancelled else { return }
            self.hideTask = nil
            self.panel.orderOut(nil)
            self.laidOutSize = nil
        }
    }

    /// Resizes to fit the content (the text changes as the clock runs) and keeps it in place.
    func relayout() {
        guard panel.isVisible, hosting.fittingSize != laidOutSize else { return }
        layout(animated: true)
    }

    private func layout(animated: Bool) {
        let size = hosting.fittingSize
        guard let frame = screen()?.visibleFrame else { return }
        let origin = PillPlacement.origin(for: position, size: size, in: frame, custom: customAnchor)
        let target = NSRect(origin: origin, size: size)
        laidOutSize = size
        guard animated, !reduceMotion, panel.isVisible, panel.frame != target else {
            positioning = true
            panel.setFrame(target, display: true)
            positioning = false
            return
        }
        frameAnimations += 1
        let panel = panel
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.22
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrame(target, display: true)
        }, completionHandler: { [weak self] in
            Task { @MainActor [weak self] in self?.frameAnimations -= 1 }
        })
    }

    /// The screen with the mouse on it: where you are working.
    private func screen() -> NSScreen? {
        NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
    }

    /// A drag: remember the spot, as a fraction of the screen so it carries over to other displays.
    private func userMoved() {
        guard !positioning, frameAnimations == 0, let frame = (panel.screen ?? screen())?.visibleFrame else { return }
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let height: CGFloat = 32
    /// Room around the capsule for its shadow.
    static let margin: CGFloat = 8

    var body: some View {
        ZStack {
            content
                .id(model.phase.kind)
                .transition(.opacity.combined(with: .scale(scale: reduceMotion ? 1 : 0.94)))
        }
        .font(.system(size: 12, weight: .medium, design: .rounded))
        .fixedSize()
        .padding(.horizontal, 14)
        // Fills the panel while it glides to a new size; the capsule clips what does not fit yet.
        .frame(minWidth: 0, maxWidth: .infinity)
        .frame(height: Self.height)
        .clipShape(Capsule())
        .modifier(PillSurface())
        .padding(Self.margin)
        .scaleEffect(model.visible || reduceMotion ? 1 : 0.88)
        .opacity(model.visible ? 1 : 0)
        .animation(.spring(response: 0.32, dampingFraction: 0.78), value: model.visible)
        .animation(.spring(response: 0.3, dampingFraction: 0.86), value: model.phase.kind)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var content: some View {
        HStack(spacing: 8) {
            switch model.phase {
            case .recording(.hold):
                RecordingDot()
                listeningText
                ModeTag(mode: model.mode)
                Waveform(levels: model.levels)
                clock

            case .recording(.handsFree):
                Image(systemName: "lock.fill").font(.system(size: 9, weight: .semibold)).foregroundStyle(.orange)
                    .accessibilityHidden(true)
                if model.liveText.isEmpty { Text("Hands-free") } else { liveWords }
                ModeTag(mode: model.mode)
                Waveform(levels: model.levels)
                if model.remaining <= 30 {
                    Text("stops in \(Int(model.remaining.rounded(.up)))s").monospacedDigit().foregroundStyle(.orange)
                } else {
                    clock
                }
                HStack(spacing: 3) {
                    Text("tap")
                    KeyCap(model.hotkeyName)
                    Text("to finish")
                }
                .foregroundStyle(.secondary)

            case let .processing(step):
                ThinkingBars()
                Text(step).contentTransition(.opacity)
                HStack(spacing: 3) {
                    KeyCap("esc")
                    Text("to cancel")
                }
                .foregroundStyle(.secondary)

            case let .status(text):
                ThinkingBars()
                Text(text).lineLimit(1).frame(maxWidth: 440)

            case let .message(text, isError):
                Image(systemName: isError ? "exclamationmark.triangle.fill" : "xmark.circle.fill")
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(isError ? Color.yellow : Color.secondary)
                Text(text).lineLimit(1).truncationMode(.tail).frame(maxWidth: 440)

            case let .done(text):
                DoneMark()
                Text(text)
            }
        }
    }

    private var clock: some View {
        Text(Self.clock(model.elapsed))
            .monospacedDigit()
            .contentTransition(.numericText())
            .animation(.snappy, value: Int(model.elapsed))
            .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private var listeningText: some View {
        if model.liveText.isEmpty { Text("Listening") } else { liveWords }
    }

    /// The end of what has been heard so far, cut at the front so the newest words show.
    private var liveWords: some View {
        Text(model.liveText)
            .lineLimit(1)
            .truncationMode(.head)
            .frame(maxWidth: 280, alignment: .trailing)
    }

    static func clock(_ seconds: TimeInterval) -> String {
        let s = Int(seconds)
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

/// Liquid Glass on macOS 26; before that, the dark frosted material of the system's own HUDs.
private struct PillSurface: ViewModifier {
    func body(content: Content) -> some View {
        #if compiler(>=6.2)
        if #available(macOS 26, *) {
            content
                .glassEffect(.regular, in: Capsule())
        } else {
            frosted(content)
        }
        #else
        frosted(content)
        #endif
    }

    private func frosted(_ content: Content) -> some View {
        content
            .background(HUDMaterial())
            .overlay(Capsule().strokeBorder(Color.white.opacity(0.14), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.25), radius: 5, y: 2)
            .environment(\.colorScheme, .dark)
    }
}

/// The blurred, dark material behind the system's volume and brightness HUDs, cut to a capsule.
private struct HUDMaterial: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        view.maskImage = Self.capsuleMask
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}

    /// Stretches to any width; the round ends keep their shape.
    private static let capsuleMask: NSImage = {
        let radius = PillView.height / 2
        let image = NSImage(size: NSSize(width: PillView.height + 1, height: PillView.height), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }()
}

/// The red recording light, breathing gently (still with Reduce Motion).
private struct RecordingDot: View {
    var body: some View {
        Image(systemName: "circle.fill")
            .font(.system(size: 8))
            .foregroundStyle(.red)
            .symbolEffect(.pulse, options: .repeating)
            .accessibilityHidden(true)
    }
}

/// A green check that bounces once as it appears.
private struct DoneMark: View {
    @State private var landed = false

    var body: some View {
        Image(systemName: "checkmark.circle.fill")
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(.green)
            .font(.system(size: 14, weight: .semibold))
            .symbolEffect(.bounce, value: landed)
            .onAppear { landed = true }
            .accessibilityHidden(true)
    }
}

/// The last 1.2 seconds of your voice, newest on the right; older bars fade out to the left.
private struct Waveform: View {
    var levels: [Float]

    var body: some View {
        HStack(alignment: .center, spacing: 1.5) {
            ForEach(levels.indices, id: \.self) { index in
                Capsule()
                    .frame(width: 2, height: Self.height(levels[index]))
                    .opacity(Self.fade(index: index, count: levels.count))
            }
        }
        .frame(height: 16)
        .foregroundStyle(.primary)
        .animation(.easeOut(duration: 0.08), value: levels)
        .accessibilityHidden(true)
    }

    /// A quiet room still shows a small line; speech fills the height. The square root makes soft
    /// speech visible without loud speech hitting the top all the time.
    static func height(_ level: Float) -> CGFloat {
        let clamped: Float = min(1, max(0, level))
        return 3 + 13 * CGFloat(clamped.squareRoot())
    }

    /// The oldest bar at 30%, the newest at full strength.
    static func fade(index: Int, count: Int) -> Double {
        let position: Double = Double(index) / Double(max(1, count - 1))
        return 0.3 + 0.7 * position
    }
}

/// Murmur's own 13 bars, a ripple running through them while it works. Still with Reduce Motion.
private struct ThinkingBars: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion)) { timeline in
            let time: TimeInterval = reduceMotion ? 0 : timeline.date.timeIntervalSinceReferenceDate
            HStack(alignment: .center, spacing: 1.5) {
                ForEach(MenuBarIcon.heights.indices, id: \.self) { index in
                    let wave: Double = Self.wave(index: index, time: time)
                    Capsule()
                        .frame(width: 2, height: Self.barHeight(index: index, wave: wave))
                        .opacity(0.45 + 0.55 * wave)
                }
            }
        }
        .frame(height: 16)
        .foregroundStyle(.primary)
        .accessibilityHidden(true)
    }

    /// 0...1: a crest that travels left to right about once a second.
    static func wave(index: Int, time: TimeInterval) -> Double {
        let x: Double = Double(index) / Double(MenuBarIcon.heights.count - 1)
        let phase: Double = x - time * 1.1
        return 0.5 + 0.5 * sin(2 * Double.pi * phase)
    }

    static func barHeight(index: Int, wave: Double) -> CGFloat {
        let base = Double(MenuBarIcon.heights[index])
        return CGFloat(3 + 11 * base * (0.6 + 0.4 * wave))
    }
}

/// A key name drawn like the key: "fn", "esc".
private struct KeyCap: View {
    let name: String
    init(_ name: String) { self.name = name }

    var body: some View {
        Text(name)
            .font(.system(size: 10, weight: .semibold, design: .rounded))
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(.quaternary))
            .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(.tertiary, lineWidth: 0.5))
    }
}

/// "Clean Up" or "Compose" next to "Listening"; nothing for plain dictation.
private struct ModeTag: View {
    var mode: DictationMode

    static func color(_ mode: DictationMode) -> Color {
        switch mode {
        case .compose: return Color.purple
        case .edit: return Color.orange
        case .dictate, .clean: return Color.blue
        }
    }

    var body: some View {
        switch mode {
        case .dictate:
            EmptyView()
        case .clean, .compose, .edit:
            Text(mode.title)
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(Capsule().fill(Self.color(mode).gradient))
                .transition(.scale.combined(with: .opacity))
        }
    }
}
#endif
