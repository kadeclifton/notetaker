import XCTest
@testable import MurmurCore

final class PillPlacementTests: XCTestCase {
    // A 1440x900 screen whose visible frame starts above a 60 pt Dock and stops under a 25 pt menu bar.
    let frame = CGRect(x: 0, y: 60, width: 1440, height: 815)
    let size = CGSize(width: 200, height: 40)

    func testPresets() {
        XCTAssertEqual(PillPlacement.origin(for: .topCenter, size: size, in: frame), CGPoint(x: 620, y: 827))
        XCTAssertEqual(PillPlacement.origin(for: .bottomCenter, size: size, in: frame), CGPoint(x: 620, y: 88))
        XCTAssertEqual(PillPlacement.origin(for: .topLeft, size: size, in: frame), CGPoint(x: 16, y: 827))
        XCTAssertEqual(PillPlacement.origin(for: .bottomRight, size: size, in: frame), CGPoint(x: 1224, y: 88))
        XCTAssertEqual(PillPosition.default, .topCenter, "clear of chat boxes, which sit at the bottom")
    }

    func testCustomSpotRoundTrips() {
        let dragged = CGRect(x: 1000, y: 500, width: 200, height: 40)
        let anchor = PillPlacement.anchor(of: dragged, in: frame)
        XCTAssertEqual(PillPlacement.origin(for: .custom, size: size, in: frame, custom: anchor).x, 1000, accuracy: 0.001)
        XCTAssertEqual(PillPlacement.origin(for: .custom, size: size, in: frame, custom: anchor).y, 500, accuracy: 0.001)

        // The same spot on a smaller screen scales with it and stays on screen.
        let small = CGRect(x: 0, y: 0, width: 800, height: 600)
        let moved = PillPlacement.origin(for: .custom, size: size, in: small, custom: anchor)
        XCTAssertTrue(small.contains(CGRect(origin: moved, size: size)))
    }

    func testNeverOffScreen() {
        let corner = PillPlacement.origin(for: .custom, size: size, in: frame, custom: CGPoint(x: 1, y: 1))
        XCTAssertEqual(corner, CGPoint(x: 1240, y: 835))
        XCTAssertEqual(PillPlacement.origin(for: .custom, size: size, in: frame, custom: nil),
                       PillPlacement.origin(for: .topCenter, size: size, in: frame), "no saved spot: the default")
        XCTAssertEqual(PillPlacement.anchor(of: CGRect(x: -500, y: 5000, width: 10, height: 10), in: frame), CGPoint(x: 0, y: 1))
    }
}
