import Foundation
#if canImport(CoreGraphics)
// CGRect's minX, maxY and friends live in CoreGraphics on Apple platforms (Foundation has them on Linux).
import CoreGraphics
#endif

/// Where the floating status pill sits on screen.
public enum PillPosition: String, CaseIterable, Sendable {
    /// Just under the menu bar: out of the way of chat boxes, which sit at the bottom.
    case topCenter
    case bottomCenter
    case topLeft
    case topRight
    case bottomLeft
    case bottomRight
    /// Wherever it was last dragged to.
    case custom

    public static let `default` = PillPosition.topCenter

    public var title: String {
        switch self {
        case .topCenter: return "Top Center"
        case .bottomCenter: return "Bottom Center"
        case .topLeft: return "Top Left"
        case .topRight: return "Top Right"
        case .bottomLeft: return "Bottom Left"
        case .bottomRight: return "Bottom Right"
        case .custom: return "Where I Dragged It"
        }
    }
}

/// Screen geometry for the pill, in AppKit's coordinates (origin at the bottom left).
public enum PillPlacement {
    static let topGap: CGFloat = 8
    static let bottomGap: CGFloat = 28
    static let sideGap: CGFloat = 16

    /// Bottom-left corner for a pill of `size` in `frame` (the screen's visible frame). A custom
    /// spot is the pill's center as a fraction of the frame, so it survives screen changes.
    public static func origin(for position: PillPosition, size: CGSize, in frame: CGRect, custom: CGPoint? = nil) -> CGPoint {
        let left = frame.minX + sideGap
        let right = frame.maxX - sideGap - size.width
        let center = frame.midX - size.width / 2
        let top = frame.maxY - topGap - size.height
        let bottom = frame.minY + bottomGap
        let point: CGPoint
        switch position {
        case .topCenter: point = CGPoint(x: center, y: top)
        case .bottomCenter: point = CGPoint(x: center, y: bottom)
        case .topLeft: point = CGPoint(x: left, y: top)
        case .topRight: point = CGPoint(x: right, y: top)
        case .bottomLeft: point = CGPoint(x: left, y: bottom)
        case .bottomRight: point = CGPoint(x: right, y: bottom)
        case .custom:
            guard let custom else { return origin(for: .default, size: size, in: frame) }
            point = CGPoint(x: frame.minX + custom.x * frame.width - size.width / 2,
                            y: frame.minY + custom.y * frame.height - size.height / 2)
        }
        return clamped(point, size: size, in: frame)
    }

    /// The fractional spot to remember after the pill was dragged to `pillFrame`.
    public static func anchor(of pillFrame: CGRect, in frame: CGRect) -> CGPoint {
        guard frame.width > 0, frame.height > 0 else { return CGPoint(x: 0.5, y: 0.9) }
        let x = (pillFrame.midX - frame.minX) / frame.width
        let y = (pillFrame.midY - frame.minY) / frame.height
        return CGPoint(x: min(1, max(0, x)), y: min(1, max(0, y)))
    }

    /// Keeps the whole pill on screen.
    static func clamped(_ point: CGPoint, size: CGSize, in frame: CGRect) -> CGPoint {
        CGPoint(x: min(max(point.x, frame.minX), max(frame.minX, frame.maxX - size.width)),
                y: min(max(point.y, frame.minY), max(frame.minY, frame.maxY - size.height)))
    }
}
