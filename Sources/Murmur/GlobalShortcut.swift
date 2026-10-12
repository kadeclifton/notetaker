#if os(macOS)
import AppKit
import Carbon.HIToolbox
import MurmurCore

/// An app-wide keyboard shortcut (Paste Last Again, Meeting Notes) through the system hotkey
/// service, which needs no permission and never sees any other key. Each instance owns one
/// shortcut; one shared handler sends each press to the instance it belongs to.
@MainActor
final class GlobalShortcut {
    private var hotKey: EventHotKeyRef?
    private let id: UInt32
    private static var nextID: UInt32 = 1
    private static var actions: [UInt32: () -> Void] = [:]
    private static var handler: EventHandlerRef?

    init() {
        id = Self.nextID
        Self.nextID += 1
    }

    /// "ctrl+option+v"; "" turns it off. False when it is not a valid shortcut or is taken.
    @discardableResult
    func register(_ shortcut: String, action: @escaping () -> Void) -> Bool {
        unregister()
        guard !shortcut.isEmpty, let spec = try? HotkeySpec.parse(shortcut),
              case let .shortcut(keyCode, modifiers, _) = spec, !modifiers.isEmpty else { return false }
        var carbon: UInt32 = 0
        if modifiers.contains(.command) { carbon |= UInt32(cmdKey) }
        if modifiers.contains(.option) { carbon |= UInt32(optionKey) }
        if modifiers.contains(.control) { carbon |= UInt32(controlKey) }
        if modifiers.contains(.shift) { carbon |= UInt32(shiftKey) }
        Self.installHandler()
        Self.actions[id] = action
        let hotKeyID = EventHotKeyID(signature: OSType(0x4D52_4D52), id: id)  // "MRMR"
        let status = RegisterEventHotKey(UInt32(keyCode), carbon, hotKeyID, GetApplicationEventTarget(), 0, &hotKey)
        if status != noErr { unregister() }
        return status == noErr
    }

    func unregister() {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        hotKey = nil
        Self.actions[id] = nil
    }

    private static func installHandler() {
        guard handler == nil else { return }
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var pressed = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                           nil, MemoryLayout<EventHotKeyID>.size, nil, &pressed)
            guard status == noErr else { return status }
            let id = pressed.id
            DispatchQueue.main.async {
                MainActor.assumeIsolated { GlobalShortcut.actions[id]?() }
            }
            return noErr
        }, 1, &type, nil, &handler)
    }
}
#endif
