#if os(macOS)
import AppKit
import CoreGraphics
import MurmurCore

enum HotkeyEvent {
    case hotkeyDown
    case hotkeyUp
    case otherKeyDown
    case escape
}

/// Watches the keyboard with a CGEventTap.
///
/// Esc and modifier-only hotkeys (fn, right option, ...) are observed and always passed
/// through, so Esc still reaches the app you are typing in. A shortcut hotkey such as
/// ctrl+option+space is swallowed so it does not type a space.
final class HotkeyMonitor {
    /// Marks events Murmur posts itself (Cmd-V, typed text) so the tap ignores them.
    static let syntheticEventMarker: Int64 = 0x4D55_524D // "MURM"

    var onEvent: (@MainActor (HotkeyEvent) -> Void)?

    private(set) var spec: HotkeySpec = .modifier(.fn)
    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var hotkeyIsDown = false

    var isRunning: Bool { tap != nil }

    /// Installs the event tap. Returns false if macOS refused (permission not granted yet).
    @discardableResult
    func start(spec: HotkeySpec) -> Bool {
        stop()
        self.spec = spec
        hotkeyIsDown = false

        let mask = (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.keyUp.rawValue)
            | (1 << CGEventType.flagsChanged.rawValue)
        // Listening needs Input Monitoring; swallowing a shortcut needs an active tap (Accessibility).
        let options: CGEventTapOptions = spec.isModifierOnly ? .listenOnly : .defaultTap
        let callback: CGEventTapCallBack = { _, type, event, userInfo in
            guard let userInfo else { return Unmanaged.passUnretained(event) }
            let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(userInfo).takeUnretainedValue()
            return monitor.handle(type: type, event: event)
        }
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: options,
            eventsOfInterest: CGEventMask(mask),
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            return false
        }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.tap = tap
        self.runLoopSource = source
        return true
    }

    func stop() {
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        tap = nil
        runLoopSource = nil
        hotkeyIsDown = false
    }

    // Runs on the main thread (the tap's run loop source is on the main run loop).
    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        let passThrough = Unmanaged.passUnretained(event)

        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            // macOS turns slow taps off; turn it back on. A key-up may have been lost, so
            // re-sync from the next event's flags (see below) and rely on the time limit.
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return passThrough
        }
        if event.getIntegerValueField(.eventSourceUserData) == Self.syntheticEventMarker {
            return passThrough
        }

        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        let flags = event.flags.rawValue

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
                    emit(.escape)
                } else if hotkeyIsDown && event.getIntegerValueField(.keyboardEventAutorepeat) == 0 {
                    emit(.otherKeyDown)
                }
            }
            return passThrough

        case let .shortcut(code, modifiers, _):
            guard type == .keyDown || type == .keyUp else { return passThrough }
            if keyCode == 53 {
                if type == .keyDown { emit(.escape) }
                return passThrough
            }
            guard keyCode == code else { return passThrough }
            if type == .keyDown {
                guard hotkeyIsDown || ShortcutModifiers(eventFlags: flags) == modifiers else { return passThrough }
                if !hotkeyIsDown && event.getIntegerValueField(.keyboardEventAutorepeat) == 0 {
                    setHotkey(down: true)
                }
                return nil // swallow, including auto-repeat
            }
            // keyUp: modifiers may already be released, so match on the key alone.
            if hotkeyIsDown {
                setHotkey(down: false)
                return nil
            }
            return passThrough
        }
    }

    private func setHotkey(down: Bool) {
        guard down != hotkeyIsDown else { return }
        hotkeyIsDown = down
        emit(down ? .hotkeyDown : .hotkeyUp)
    }

    private func emit(_ event: HotkeyEvent) {
        MainActor.assumeIsolated {
            onEvent?(event)
        }
    }
}
#endif
