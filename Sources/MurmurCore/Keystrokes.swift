import Foundation

/// Splits text into pieces that can be sent as synthetic key events.
public enum Keystrokes {
    public enum Piece: Equatable, Sendable {
        /// UTF-16 units for one event's unicode string.
        case text([UInt16])
        /// Sent as a Return key press; many apps ignore "\n" inside a unicode string.
        case newline
    }

    /// A key event carries at most about 20 UTF-16 units. Chunks break only between
    /// characters, so an emoji's surrogate pair or a flag never gets split across events.
    public static func pieces(for text: String, maxUnits: Int = 20) -> [Piece] {
        var pieces: [Piece] = []
        var chunk: [UInt16] = []
        func flush() {
            if !chunk.isEmpty { pieces.append(.text(chunk)) }
            chunk = []
        }
        for character in text {
            if character.isNewline {
                flush()
                pieces.append(.newline)
                continue
            }
            let units = Array(String(character).utf16)
            if !chunk.isEmpty && chunk.count + units.count > maxUnits { flush() }
            chunk += units
        }
        flush()
        return pieces
    }
}
