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
    /// Called on the main thread with the other modifiers (⌃, ⌥, …) held while a modifier-only
    /// hotkey is down: at the press, and whenever they change. They pick the dictation mode.
    var onModifiers: (@MainActor (ShortcutModifiers) -> Void)?

    private var current: TapContext?

    var isRunning: Bool { current != nil }

    /// With a modifier hotkey (fn), whether to watch every key press: needed for Esc and for keys
    /// pressed with the hotkey only while Murmur records or works. Off, typing in other apps does
    /// not wake Murmur at all. Key presses are always watched while the hotkey is held.
    var watchKeys = false {
        didSet {
            guard watchKeys != oldValue else { return }
            current?.setWatchKeys(watchKeys)
        }
    }

    /// Installs the event tap. Returns false if macOS refused (permission not granted yet).
    @discardableResult
    func start(spec: HotkeySpec) -> Bool {
        stop()
        let context = TapContext(spec: spec, emit: { [weak self] input, time in
            let monitor = self
            DispatchQueue.main.async {
                MainActor.assumeIsolated { monitor?.onInput?(input, time) }
            }
        }, emitModifiers: { [weak self] modifiers in
            let monitor = self
            DispatchQueue.main.async {
                MainActor.assumeIsolated { monitor?.onModifiers?(modifiers) }
            }
        })
        guard context.run() else { return false }
        context.setWatchKeys(watchKeys)
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
    private let emitModifiers: (ShortcutModifiers) -> Void
    private var tap: CFMachPort?
    /// Modifier hotkeys only: key presses, in a tap of their own that is off unless they matter.
    private var keysTap: CFMachPort?
    private var runLoop: CFRunLoop?
    private var hotkeyIsDown = false
    private let lock = NSLock()
    private var stopped = false
    /// Under `lock`: what the keys tap needs to be on for.
    private var watchKeys = false
    private var hotkeyHeld = false

    init(spec: HotkeySpec, emit: @escaping (DictationInput, TimeInterval) -> Void,
         emitModifiers: @escaping (ShortcutModifiers) -> Void) {
        self.spec = spec
        self.emit = emit
        self.emitModifiers = emitModifiers
    }

    /// Starts the tap thread and waits until the tap exists (or failed to).
    func run() -> Bool {
        let ready = DispatchSemaphore(value: 0)
        let created = Flag()
        let thread = Thread { [self] in
            // A modifier hotkey only needs modifier changes all the time; key presses get their own
            // tap, switched on when they matter. If that tap cannot be made, one tap does both.
            let keys = spec.isModifierOnly ? makeTap(mask: Self.mask(.keyDown)) : nil
            let mask: UInt64
            switch spec {
            case .modifier: mask = Self.mask(.flagsChanged) | (keys == nil ? Self.mask(.keyDown) : 0)
            case .shortcut: mask = Self.mask(.keyDown) | Self.mask(.keyUp)
            }
            guard let tap = makeTap(mask: mask) else {
                if let keys { CFMachPortInvalidate(keys) }
                ready.signal()
                return
            }
            let loop = CFRunLoopGetCurrent()
            var sources: [CFRunLoopSource] = []
            for port in [tap, keys].compactMap({ $0 }) {
                guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0) else { continue }
                CFRunLoopAddSource(loop, source, .commonModes)
                sources.append(source)
            }
            CGEvent.tapEnable(tap: tap, enable: true)
            if let keys { CGEvent.tapEnable(tap: keys, enable: false) }
            lock.withLock {
                self.tap = tap
                self.keysTap = keys
                self.runLoop = loop
            }
            updateKeysTap()
            created.value = true
            ready.signal()
            // Sleeps until stop() stops this run loop. The timeout only matters if stop() came
            // between storing the loop above and running it, so it can be long: the thread must
            // not wake every second for nothing.
            while !lock.withLock({ stopped }) {
                CFRunLoopRunInMode(.defaultMode, 60, false)
            }
            for port in [tap, keys].compactMap({ $0 }) {
                CGEvent.tapEnable(tap: port, enable: false)
                CFMachPortInvalidate(port)
            }
            for source in sources { CFRunLoopRemoveSource(loop, source, .commonModes) }
        }
        thread.name = "Murmur hotkey tap"
        thread.qualityOfService = QualityOfService.userInteractive
        thread.start()
        ready.wait()
        return created.value
    }

    func stop() {
        let (taps, loop) = lock.withLock { () -> ([CFMachPort], CFRunLoop?) in
            stopped = true
            return ([tap, keysTap].compactMap { $0 }, runLoop)
        }
        // Disable right away so the old taps cannot deliver events while the thread winds down.
        for tap in taps { CGEvent.tapEnable(tap: tap, enable: false) }
        if let loop { CFRunLoopStop(loop) }
    }

    /// From the main thread: Murmur is recording or working (or not any more).
    func setWatchKeys(_ on: Bool) {
        lock.withLock { watchKeys = on }
        updateKeysTap()
    }

    /// The keys tap is on while the hotkey is held or Murmur wants Esc; off otherwise.
    private func updateKeysTap() {
        let (keys, on) = lock.withLock { (keysTap, !stopped && (watchKeys || hotkeyHeld)) }
        if let keys { CGEvent.tapEnable(tap: keys, enable: on) }
    }

    private static func mask(_ type: CGEventType) -> UInt64 { 1 << UInt64(type.rawValue) }

    private func makeTap(mask: UInt64) -> CFMachPort? {
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
            updateKeysTap()
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
                // Sent after hotkeyDown, so the recording it belongs to has already started.
                if hotkeyIsDown { emitModifiers(key.extraModifiers(flags: flags)) }
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
        // Keys pressed with the hotkey (fn+F5, fn+←) must be seen from the very next event, before
        // the main thread has heard of the press, so the tap switches itself on here.
        lock.withLock { hotkeyHeld = down }
        updateKeysTap()
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
