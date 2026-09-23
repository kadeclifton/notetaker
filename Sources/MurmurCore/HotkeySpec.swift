import Foundation

/// A modifier key that can be held on its own as the hotkey.
public enum ModifierKey: String, CaseIterable, Sendable {
    case fn
    case leftControl, rightControl
    case leftOption, rightOption
    case leftCommand, rightCommand
    case leftShift, rightShift

    /// macOS virtual key code (kVK_*).
    public var keyCode: Int64 {
        switch self {
        case .fn: return 63
        case .leftControl: return 59
        case .rightControl: return 62
        case .leftOption: return 58
        case .rightOption: return 61
        case .leftCommand: return 55
        case .rightCommand: return 54
        case .leftShift: return 56
        case .rightShift: return 60
        }
    }

    /// Bit in CGEventFlags that is set while this key is down. fn uses the
    /// device-independent secondary-fn flag; the others use the device-dependent
    /// NX_DEVICE* bits so left and right are told apart.
    public var flagMask: UInt64 {
        switch self {
        case .fn: return 0x0080_0000
        case .leftControl: return 0x0000_0001
        case .rightControl: return 0x0000_2000
        case .leftOption: return 0x0000_0020
        case .rightOption: return 0x0000_0040
        case .leftCommand: return 0x0000_0008
        case .rightCommand: return 0x0000_0010
        case .leftShift: return 0x0000_0002
        case .rightShift: return 0x0000_0004
        }
    }

    public func isDown(flags: UInt64) -> Bool { flags & flagMask != 0 }

    public var symbol: String {
        switch self {
        case .fn: return "fn"
        case .leftControl: return "left ⌃"
        case .rightControl: return "right ⌃"
        case .leftOption: return "left ⌥"
        case .rightOption: return "right ⌥"
        case .leftCommand: return "left ⌘"
        case .rightCommand: return "right ⌘"
        case .leftShift: return "left ⇧"
        case .rightShift: return "right ⇧"
        }
    }
}

/// Device-independent modifier flags a shortcut can require.
public struct ShortcutModifiers: OptionSet, Hashable, Sendable {
    public let rawValue: UInt64
    public init(rawValue: UInt64) { self.rawValue = rawValue }

    // Same values as CGEventFlags.
    public static let shift = ShortcutModifiers(rawValue: 0x0002_0000)
    public static let control = ShortcutModifiers(rawValue: 0x0004_0000)
    public static let option = ShortcutModifiers(rawValue: 0x0008_0000)
    public static let command = ShortcutModifiers(rawValue: 0x0010_0000)

    public static let all: ShortcutModifiers = [.shift, .control, .option, .command]

    /// The modifiers present in a raw CGEventFlags value, ignoring fn, caps lock and the rest.
    public init(eventFlags: UInt64) {
        self.init(rawValue: eventFlags & ShortcutModifiers.all.rawValue)
    }
}

public enum HotkeySpec: Equatable, Sendable {
    /// A modifier held by itself, like fn. Observed passively; never swallowed.
    case modifier(ModifierKey)
    /// A key plus zero or more modifiers, like ctrl+option+space. Swallowed so it does not type.
    case shortcut(keyCode: Int64, modifiers: ShortcutModifiers, display: String)

    public var isModifierOnly: Bool {
        if case .modifier = self { return true }
        return false
    }

    public var displayName: String {
        switch self {
        case let .modifier(key): return key.symbol
        case let .shortcut(_, _, display): return display
        }
    }

    public enum ParseError: Error, CustomStringConvertible, Equatable {
        case empty
        case unknownKey(String)
        case escapeNotAllowed
        case noKey(String)

        public var description: String {
            switch self {
            case .empty: return "The hotkey is empty."
            case let .unknownKey(k): return "Unknown key \"\(k)\" in hotkey."
            case .escapeNotAllowed: return "Esc is reserved for cancelling; pick another hotkey."
            case let .noKey(s): return "\"\(s)\" has modifiers but no key. Use e.g. \"ctrl+option+space\", or a single modifier like \"rightOption\"."
            }
        }
    }

    /// Parses "fn", "rightOption", "ctrl+option+space", "cmd+shift+d", "f13".
    public static func parse(_ string: String) throws -> HotkeySpec {
        let trimmed = string.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { throw ParseError.empty }

        let normalized = trimmed.lowercased().replacingOccurrences(of: "_", with: "").replacingOccurrences(of: "-", with: "")
        if let key = modifierAliases[normalized] { return .modifier(key) }

        let parts = trimmed.split(separator: "+").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        var modifiers: ShortcutModifiers = []
        var keyCode: Int64?
        var keyName = ""
        for part in parts {
            if let m = shortcutModifierAliases[part] {
                modifiers.insert(m)
            } else if let code = keyCodes[part] {
                guard keyCode == nil else { throw ParseError.unknownKey(part) }
                if code == 53 { throw ParseError.escapeNotAllowed }
                keyCode = code
                keyName = part
            } else {
                throw ParseError.unknownKey(part)
            }
        }
        guard let keyCode else { throw ParseError.noKey(trimmed) }

        var display = ""
        if modifiers.contains(.control) { display += "⌃" }
        if modifiers.contains(.option) { display += "⌥" }
        if modifiers.contains(.shift) { display += "⇧" }
        if modifiers.contains(.command) { display += "⌘" }
        display += keyName.count == 1 ? keyName.uppercased() : keyName.capitalized
        return .shortcut(keyCode: keyCode, modifiers: modifiers, display: display)
    }

    static let modifierAliases: [String: ModifierKey] = [
        "fn": .fn, "globe": .fn, "function": .fn,
        "leftcontrol": .leftControl, "leftctrl": .leftControl, "lctrl": .leftControl,
        "rightcontrol": .rightControl, "rightctrl": .rightControl, "rctrl": .rightControl,
        "leftoption": .leftOption, "leftalt": .leftOption, "lopt": .leftOption, "lalt": .leftOption,
        "rightoption": .rightOption, "rightalt": .rightOption, "ropt": .rightOption, "ralt": .rightOption,
        "leftcommand": .leftCommand, "leftcmd": .leftCommand, "lcmd": .leftCommand,
        "rightcommand": .rightCommand, "rightcmd": .rightCommand, "rcmd": .rightCommand,
        "leftshift": .leftShift, "lshift": .leftShift,
        "rightshift": .rightShift, "rshift": .rightShift,
    ]

    static let shortcutModifierAliases: [String: ShortcutModifiers] = [
        "ctrl": .control, "control": .control, "⌃": .control,
        "opt": .option, "option": .option, "alt": .option, "⌥": .option,
        "cmd": .command, "command": .command, "⌘": .command,
        "shift": .shift, "⇧": .shift,
    ]

    /// ANSI virtual key codes.
    static let keyCodes: [String: Int64] = {
        var map: [String: Int64] = [
            "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9,
            "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17,
            "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "=": 24, "9": 25, "7": 26,
            "-": 27, "8": 28, "0": 29, "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35,
            "l": 37, "j": 38, "'": 39, "k": 40, ";": 41, "\\": 42, ",": 43, "/": 44,
            "n": 45, "m": 46, ".": 47, "`": 50,
            "return": 36, "enter": 36, "tab": 48, "space": 49, "delete": 51, "backspace": 51,
            "escape": 53, "esc": 53, "forwarddelete": 117,
            "home": 115, "end": 119, "pageup": 116, "pagedown": 121,
            "left": 123, "right": 124, "down": 125, "up": 126,
        ]
        let fKeys: [Int64] = [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111,
                              105, 107, 113, 106, 64, 79, 80, 90]
        for (i, code) in fKeys.enumerated() { map["f\(i + 1)"] = code }
        return map
    }()
}
