import XCTest

/// Tests delivered touch behavior; XCTest presence/hit points do not prove VoiceOver traversal.
@MainActor
struct IPadFocusBackgroundTap {
    private static let timeout: TimeInterval = 30
    private static let observationDuration: TimeInterval = 1
    private let target: XCUIElement
    private let name: String
    private let point: CGPoint
    private let windowFrame: CGRect

    init(_ target: XCUIElement, in app: XCUIApplication, position: CGVector = CGVector(dx: 0.5, dy: 0.5)) throws {
        XCTAssertTrue(target.wait(for: \.isHittable, toEqual: true, timeout: Self.timeout))
        let frame = target.frame
        let point = CGPoint(x: frame.minX + frame.width * position.dx, y: frame.minY + frame.height * position.dy)
        let windowFrame = app.windows.firstMatch.frame
        self.windowFrame = windowFrame
        self.point = try XCTUnwrap(!frame.isEmpty && windowFrame.contains(point) ? point : nil, "Background control must have an on-screen baseline point")
        self.target = target
        name = target.identifier.isEmpty ? target.label : target.identifier
    }

    func activate(in app: XCUIApplication) throws {
        XCTAssertTrue(target.wait(for: \.isHittable, toEqual: true, timeout: Self.timeout))
        _ = try XCTUnwrap(target.frame.contains(point) ? point : nil, "The saved point must still hit \(name) when restored")
        try coordinate(in: app).tap()
    }

    func assertBlocked(in app: XCUIApplication, focusedPane: CGRect, unchanged: () throws -> Bool) throws {
        let keyboard = app.keyboards.firstMatch
        let outsideKeyboard = !keyboard.exists || !keyboard.frame.insetBy(dx: -1, dy: -1).contains(point)
        _ = try XCTUnwrap(
            !focusedPane.insetBy(dx: -1, dy: -1).contains(point) && outsideKeyboard ? point : nil,
            "Saved \(name) point \(point) must be outside the measured focused pane and keyboard"
        )
        XCTAssertTrue(try unchanged(), "Focus/context baseline must be valid before testing \(name)")
        try coordinate(in: app).tap()
        // A real navigation action closes focus; a menu exposes its own controls.
        // Observe actual state after delivery instead of trusting hidden elements' isHittable.
        let changed = waitUntil(timeout: Self.observationDuration) { (try? unchanged()) != true }
        XCTAssertFalse(changed, "Background \(name) changed focus or context after a coordinate tap")
    }

    static func paneFrame(_ identifier: String, in app: XCUIApplication) throws -> CGRect {
        let probes = app.otherElements.matching(identifier: "\(identifier).geometry")
        XCTAssertTrue(probes.firstMatch.waitForExistence(timeout: timeout))
        XCTAssertEqual(probes.count, 1, "The pane must have exactly one independent geometry probe")
        let frame = probes.firstMatch.frame
        return try XCTUnwrap(
            !frame.isEmpty && app.windows.firstMatch.frame.insetBy(dx: -1, dy: -1).contains(frame) ? frame : nil,
            "The measured pane must be nonempty and contained by the window"
        )
    }

    private func coordinate(in app: XCUIApplication) throws -> XCUICoordinate {
        let window = app.windows.firstMatch
        XCTAssertEqual(window.frame, windowFrame, "Restore the captured orientation before using a saved background point")
        let point = try XCTUnwrap(window.frame.contains(point) ? point : nil, "Saved background point must remain on-screen")
        return window.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: point.x - window.frame.minX, dy: point.y - window.frame.minY))
    }
}
