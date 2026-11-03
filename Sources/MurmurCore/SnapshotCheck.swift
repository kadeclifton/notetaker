import Foundation

/// Whether a screenshot shows anything. The screenshot tests (`Murmur --snapshots`) fail any
/// window that drew nothing, like 0.2.5's Settings, which opened with its title and no content.
///
/// "Something" means sharp edges: text, icons, controls and their borders. A plain background, a
/// gradient, or the desktop blurred behind a sidebar has almost none, so those count as blank
/// even when they have plenty of colors.
public enum SnapshotCheck {
    public struct Region: Equatable, Sendable {
        public var x: Int
        public var y: Int
        public var width: Int
        public var height: Int

        public init(x: Int, y: Int, width: Int, height: Int) {
            self.x = x
            self.y = y
            self.width = width
            self.height = height
        }
    }

    public struct Result: Equatable, Sendable {
        /// Share of pixels with a sharp step in brightness to the next pixel right or below.
        public var edges: Double
        /// Distinct colors at 5 bits a channel, for the report.
        public var colors: Int

        /// A short label of text is about 0.5% edges in a settings-sized window; an empty window,
        /// gradient or blurred sidebar stays far below 0.05%.
        public static let threshold = 0.0005

        public var isBlank: Bool { edges < Self.threshold }
    }

    /// The smallest step in brightness (0...255) that counts as an edge.
    static let step = 48

    /// `rgba`: 4 bytes a pixel (premultiplied alpha), rows top to bottom. `region` (in pixels,
    /// from the top left) limits the check to part of the image; it is clipped to the image.
    public static func analyze(rgba: [UInt8], width: Int, height: Int, region: Region? = nil) -> Result {
        let area = clipped(region ?? Region(x: 0, y: 0, width: width, height: height), width: width, height: height)
        guard area.width > 1, area.height > 1, rgba.count >= width * height * 4 else { return Result(edges: 0, colors: 0) }

        func brightness(_ x: Int, _ y: Int) -> Int {
            let i = (y * width + x) * 4
            return (Int(rgba[i]) * 299 + Int(rgba[i + 1]) * 587 + Int(rgba[i + 2]) * 114) / 1000
        }
        func alpha(_ x: Int, _ y: Int) -> Int { Int(rgba[(y * width + x) * 4 + 3]) }
        /// A step in brightness, or in opacity: anything drawn on a see-through window (the pill) counts.
        func step(_ x: Int, _ y: Int, _ x2: Int, _ y2: Int) -> Int {
            max(abs(brightness(x, y) - brightness(x2, y2)), abs(alpha(x, y) - alpha(x2, y2)))
        }

        var edges = 0
        var colors = Set<UInt32>()
        for y in area.y..<(area.y + area.height) {
            for x in area.x..<(area.x + area.width) {
                let i = (y * width + x) * 4
                colors.insert(UInt32(rgba[i] >> 3) << 15 | UInt32(rgba[i + 1] >> 3) << 10
                              | UInt32(rgba[i + 2] >> 3) << 5 | UInt32(rgba[i + 3] >> 3))
                let right = x + 1 < area.x + area.width ? step(x, y, x + 1, y) : 0
                let below = y + 1 < area.y + area.height ? step(x, y, x, y + 1) : 0
                if max(right, below) >= Self.step { edges += 1 }
            }
        }
        return Result(edges: Double(edges) / Double(area.width * area.height), colors: colors.count)
    }

    static func clipped(_ region: Region, width: Int, height: Int) -> Region {
        let x = min(max(0, region.x), width)
        let y = min(max(0, region.y), height)
        return Region(x: x, y: y, width: max(0, min(region.width, width - x)), height: max(0, min(region.height, height - y)))
    }
}
