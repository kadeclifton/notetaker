import Foundation

/// What happens to a dictation after Whisper hears it.
public enum DictationMode: String, Codable, Sendable, CaseIterable {
    /// Exactly what Whisper heard, inserted at once. No language model.
    case dictate
    /// Filler words out, punctuation fixed, words kept (the cleanup LLM).
    case clean
    /// A rambling draft turned into finished writing, shown in a preview before inserting.
    case compose
    /// What you say is an instruction for the selected text ("make this shorter"); the selection
    /// is replaced with the result.
    case edit

    public var title: String {
        switch self {
        case .dictate: return "Dictate"
        case .clean: return "Clean Up"
        case .compose: return "Compose"
        case .edit: return "Edit"
        }
    }
}

/// Which extra modifiers were held with the hotkey. Only ever goes up during one recording:
/// pressing ⌃ halfway through still counts, and letting go of it early does not undo it.
public enum ModeKeys: Int, Comparable, Sendable, CaseIterable {
    /// The hotkey alone.
    case plain
    /// Hotkey + ⌃.
    case control
    /// Hotkey + ⌃ + ⌥.
    case controlOption
    /// Hotkey + ⇧: edit the selection. Wins over the others whenever ⇧ joins.
    case shift

    public init(extraModifiers modifiers: ShortcutModifiers) {
        if modifiers.contains(.shift) {
            self = .shift
        } else if modifiers.contains(.control) {
            self = modifiers.contains(.option) ? .controlOption : .control
        } else {
            self = .plain
        }
    }

    public static func < (lhs: ModeKeys, rhs: ModeKeys) -> Bool { lhs.rawValue < rhs.rawValue }

    /// "fn", "fn⌃", "fn⌃⌥".
    public func label(hotkey: String) -> String {
        switch self {
        case .plain: return hotkey
        case .control: return hotkey + "⌃"
        case .controlOption: return hotkey + "⌃⌥"
        case .shift: return hotkey + "⇧"
        }
    }
}

public struct ModesConfig: Codable, Equatable, Sendable {
    /// The hotkey on its own.
    public var hotkey: DictationMode = .dictate
    /// Hotkey + ⌃.
    public var withControl: DictationMode = .clean
    /// Hotkey + ⌃ + ⌥.
    public var withControlOption: DictationMode = .compose
    /// Hotkey + ⇧.
    public var withShift: DictationMode = .edit

    public init() {}

    public func mode(for keys: ModeKeys) -> DictationMode {
        switch keys {
        case .plain: return hotkey
        case .control: return withControl
        case .controlOption: return withControlOption
        case .shift: return withShift
        }
    }
}

extension ModifierKey {
    /// The device-independent flag this key sets itself, which does not count as an extra modifier.
    public var shortcutModifier: ShortcutModifiers {
        switch self {
        case .fn: return []
        case .leftControl, .rightControl: return .control
        case .leftOption, .rightOption: return .option
        case .leftCommand, .rightCommand: return .command
        case .leftShift, .rightShift: return .shift
        }
    }

    /// Modifiers held along with this key, from a raw CGEventFlags value.
    public func extraModifiers(flags: UInt64) -> ShortcutModifiers {
        ShortcutModifiers(eventFlags: flags).subtracting(shortcutModifier)
    }
}
