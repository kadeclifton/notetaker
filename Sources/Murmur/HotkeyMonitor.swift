#if os(macOS)
import AppKit
import CoreGraphics
import MurmurCore

/// Watches the keyboard with a CGEventTap on its own thread.
///
/// Esc and modifier-only hotkeys (fn, right option, ...) are observed and always passed
/// through, so Esc still reaches the app you are typing in. A shortcut hotkey such as
/// ctrl+option+space is swallowed so it does not type a space.
///
/// The tap runs off the main thread and hands events to the main thread asynchronously,
/// so slow work there (starting a Bluetooth mic) never stalls typing or trips macOS's
/// tap timeout.
final class HotkeyMonitor: @unchecked Sendable {
    /// Marks events Murmur posts itself (Cmd-V, typed text) so the tap ignores them.
    static let syntheticEventMarker: Int64 = 0x4D55_524D // "MURM"

    /// Called on the main thread with the input and the uptime at which the key event happened.
    var onInput: (@MainActor (DictationInput, TimeInterval) -> Void)?

    private var current: TapContext?

    var isRunning: Bool { current != nil }

    /// Installs the event tap. Returns false if macOS refused (permission not granted yet).
    @discardableResult
    func start(spec: HotkeySpec) -> Bool {
        stop()
        let context = TapContext(spec: spec) { [weak self] input, time in
            let monitor = self
            DispatchQueue.main.async {
                MainActor.assumeIsolated { monitor?.onInput?(input, time) }
            }
        }
        guard context.run() else { return false }
        current = context
        return true
    }

    func stop() {
        current?.stop()
        current = nil
    }
}

/// One installed tap and the state it owns. Everything except `stop()` runs on the tap's thread.
private final class TapContext: @unchecked Sendable {
    let spec: HotkeySpec
    private let emit: (DictationInput, TimeInterval) -> Void
    private var tap: CFMachPort?
    private var runLoop: CFRunLoop?
    private var hotkeyIsDown = false
    private let lock = NSLock()
    private var stopped = false

    init(spec: HotkeySpec, emit: @escaping (DictationInput, TimeInterval) -> Void) {
        self.spec = spec
        self.emit = emit
    }

    /// Starts the tap thread and waits until the tap exists (or failed to).
    func run() -> Bool {
        let ready = DispatchSemaphore(value: 0)
        let created = Flag()
        let thread = Thread { [self] in
            guard let tap = makeTap() else {
                ready.signal()
                return
            }
            let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
            let loop = CFRunLoopGetCurrent()
            CFRunLoopAddSource(loop, source, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
            lock.withLock {
                self.tap = tap
                self.runLoop = loop
            }
            created.value = true
            ready.signal()
            // Wake at least once a second so a stop() that raced the start is still noticed.
            while !lock.withLock({ stopped }) {
                CFRunLoopRunInMode(.defaultMode, 1, false)
            }
            CGEvent.tapEnable(tap: tap, enable: false)
            CFRunLoopRemoveSource(loop, source, .commonModes)
            CFMachPortInvalidate(tap)
        }
        thread.name = "Murmur hotkey tap"
        thread.qualityOfService = .userInteractive
        thread.start()
        ready.wait()
        return created.value
    }

    func stop() {
        let (tap, loop) = lock.withLock { () -> (CFMachPort?, CFRunLoop?) in
            stopped = true
            return (self.tap, runLoop)
        }
        // Disable right away so the old tap cannot deliver events while the thread winds down.
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let loop { CFRunLoopStop(loop) }
    }

    private func makeTap() -> CFMachPort? {
        let mask = (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.keyUp.rawValue)
            | (1 << CGEventType.flagsChanged.rawValue)
        // Listening needs Input Monitoring; swallowing a shortcut needs an active tap (Accessibility).
        let options: CGEventTapOptions = spec.isModifierOnly ? .listenOnly : .defaultTap
        let callback: CGEventTapCallBack = { _, type, event, userInfo in
            guard let userInfo else { return Unmanaged.passUnretained(event) }
            let context = Unmanaged<TapContext>.fromOpaque(userInfo).takeUnretainedValue()
            return context.handle(type: type, event: event)
        }
        return CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: options,
            eventsOfInterest: CGEventMask(mask),
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        )
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        let passThrough = Unmanaged.passUnretained(event)
        if lock.withLock({ stopped }) { return passThrough }

        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            // macOS turned the tap off, so key-ups may have been missed. Turn it back on and
            // ask the hardware whether the hotkey is really still down.
            if let tap = lock.withLock({ self.tap }) { CGEvent.tapEnable(tap: tap, enable: true) }
            if hotkeyIsDown && !hotkeyPhysicallyDown() { setHotkey(down: false) }
            return passThrough
        }
        if event.getIntegerValueField(.eventSourceUserData) == HotkeyMonitor.syntheticEventMarker {
            return passThrough
        }

        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        let flags = event.flags.rawValue
        let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0

        switch spec {
        case let .modifier(key):
            if type == .flagsChanged {
                if keyCode == key.keyCode {
                    setHotkey(down: key.isDown(flags: flags))
                } else if hotkeyIsDown && !key.isDown(flags: flags) {
                    setHotkey(down: false)
                }
                return passThrough
            }
            if type == .keyDown {
                // A lost key-up shows up as the flag missing on the next key press.
                if hotkeyIsDown && !key.isDown(flags: flags) { setHotkey(down: false) }
                if keyCode == 53 {
                    send(.escape)
                } else if hotkeyIsDown && !isRepeat {
                    send(.otherKeyDown)
                }
            }
            return passThrough

        case let .shortcut(code, modifiers, _):
            guard type == .keyDown || type == .keyUp else { return passThrough }
            if keyCode == 53 {
                if type == .keyDown { send(.escape) }
                return passThrough
            }
            guard keyCode == code else { return passThrough }
            if type == .keyUp {
                // Modifiers may already be released, so match on the key alone.
                guard hotkeyIsDown else { return passThrough }
                setHotkey(down: false)
                return nil
            }
            if isRepeat {
                return hotkeyIsDown ? nil : passThrough
            }
            if ShortcutModifiers(eventFlags: flags) == modifiers {
                setHotkey(down: true)
                return nil
            }
            // The bare key (e.g. Space without ctrl+option): it is typing, never the hotkey.
            // If we still think the hotkey is held, a key-up was lost; resync.
            if hotkeyIsDown { setHotkey(down: false) }
            return passThrough
        }
    }

    private func hotkeyPhysicallyDown() -> Bool {
        switch spec {
        case let .modifier(key):
            return key.isDown(flags: CGEventSource.flagsState(.combinedSessionState).rawValue)
        case let .shortcut(code, _, _):
            return CGEventSource.keyState(.combinedSessionState, key: CGKeyCode(code))
        }
    }

    private func setHotkey(down: Bool) {
        guard down != hotkeyIsDown else { return }
        hotkeyIsDown = down
        send(down ? .hotkeyDown : .hotkeyUp)
    }

    private func send(_ input: DictationInput) {
        emit(input, ProcessInfo.processInfo.systemUptime)
    }
}

private final class Flag: @unchecked Sendable {
    var value = false
}
#endif
