#if os(macOS)
import AppKit

/// The menu bar icon: the app icon's 13 bars, the loudness of the word "murmur" spoken aloud.
/// Drawn in code so it is crisp at any scale; a template image, so macOS tints it for light,
/// dark and highlighted menu bars. Keep `heights` in sync with HEIGHTS in scripts/make-icon.py.
enum MenuBarIcon {
    enum Style {
        case idle
        /// Bars cut out of a filled pill, like the system's own recording indicators.
        case recording
        /// Dictation switched off: the bars, faded.
        case off
    }

    static let heights: [CGFloat] = [0.19, 0.24, 0.80, 1.00, 0.80, 0.69, 0.56, 0.19, 0.16, 0.69, 0.67, 0.58, 0.42]

    static func image(_ style: Style) -> NSImage {
        // 1 pt bars with 1 pt gaps: at 2x that is 2 px bars and 2 px gaps, so they never blur together.
        let bar: CGFloat = 1
        let gap: CGFloat = 1
        let padding: CGFloat = style == .recording ? 3 : 0
        let tallest: CGFloat = style == .recording ? 12 : 15
        let barsWidth = CGFloat(heights.count) * bar + CGFloat(heights.count - 1) * gap
        let size = NSSize(width: barsWidth + padding * 2, height: 18)

        let image = NSImage(size: size, flipped: false) { rect in
            if style == .recording {
                NSColor.black.setFill()
                NSBezierPath(roundedRect: rect.insetBy(dx: 0, dy: 1), xRadius: 4, yRadius: 4).fill()
                NSGraphicsContext.current?.compositingOperation = .destinationOut
            }
            (style == .off ? NSColor.black.withAlphaComponent(0.4) : NSColor.black).setFill()
            for (index, level) in heights.enumerated() {
                let height = max(bar, tallest * level)
                let barRect = NSRect(x: padding + CGFloat(index) * (bar + gap), y: rect.midY - height / 2,
                                     width: bar, height: height)
                NSBezierPath(roundedRect: barRect, xRadius: bar / 2, yRadius: bar / 2).fill()
            }
            NSGraphicsContext.current?.compositingOperation = .sourceOver
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Murmur"
        return image
    }
}
#endif
