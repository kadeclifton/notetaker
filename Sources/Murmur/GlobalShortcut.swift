#if os(macOS)
import AppKit
import Carbon.HIToolbox
import MurmurCore

/// One app-wide keyboard shortcut (Paste Last Again) through the system hotkey service, which
/// needs no permission and never sees any other key.
@MainActor
final class GlobalShortcut {
    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private var action: (() -> Void)?
    private static weak var current: GlobalShortcut?

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
        self.action = action
        Self.current = self
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { GlobalShortcut.current?.action?() }
            }
            return noErr
        }, 1, &type, nil, &handler)
        let id = EventHotKeyID(signature: OSType(0x4D52_4D52), id: 1)  // "MRMR"
        let status = RegisterEventHotKey(UInt32(keyCode), carbon, id, GetApplicationEventTarget(), 0, &hotKey)
        if status != noErr { unregister() }
        return status == noErr
    }

    func unregister() {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let handler { RemoveEventHandler(handler) }
        hotKey = nil
        handler = nil
        action = nil
    }
}
#endif
