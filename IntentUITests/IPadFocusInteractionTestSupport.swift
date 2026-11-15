import XCTest

/// Tests delivered touch behavior; XCTest presence/hit points do not prove VoiceOver traversal.
@MainActor
struct IPadFocusBackgroundTap {
    private static let timeout: TimeInterval = 30
    private static let observationDuration: TimeInterval = 1
    private static let restorationObservationDuration: TimeInterval = 5
    private let target: XCUIElement
    private let name: String
    private let point: CGPoint
    private let windowFrame: CGRect
    private let nativeBaseline: String?

    init(_ target: XCUIElement, in app: XCUIApplication, position: CGVector = CGVector(dx: 0.5, dy: 0.5), recordsRestoration: Bool = false) throws {
        XCTAssertTrue(target.wait(for: \.isHittable, toEqual: true, timeout: Self.timeout))
        let frame = target.frame
        let point = CGPoint(x: frame.minX + frame.width * position.dx, y: frame.minY + frame.height * position.dy)
        let windowFrame = app.windows.firstMatch.frame
        self.windowFrame = windowFrame
        self.point = try XCTUnwrap(!frame.isEmpty && windowFrame.contains(point) ? point : nil, "Background control must have an on-screen baseline point")
        self.target = target
        name = target.identifier.isEmpty ? target.label : target.identifier
        nativeBaseline = recordsRestoration ? Self.nativeReport(in: app) : nil
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

    /// Called only after the acceptance wait failed. Never changes its saved result.
    func recordRestorationFailure(in app: XCUIApplication, name diagnosticName: String, activated: () -> Bool) {
        func attach(_ text: String, phase: String, to activity: any XCTActivity) {
            let attachment = XCTAttachment(string: text)
            attachment.name = "\(diagnosticName)-\(phase).txt"
            attachment.lifetime = .keepAlways
            activity.add(attachment)
        }
        XCTContext.runActivity(named: diagnosticName) { activity in
            attach(nativeBaseline ?? "No native baseline recorded", phase: "baseline-native", to: activity)
            for attachment in Self.failureAttachments(in: app, name: diagnosticName, phase: "before") { activity.add(attachment) }
            let window = app.windows.firstMatch
            let keyboard = app.keyboards.firstMatch
            let targetFrame = target.exists ? target.frame : .zero
            let pointValid = window.frame == windowFrame && window.frame.contains(point)
                && targetFrame.contains(point)
                && (!keyboard.exists || !keyboard.frame.contains(point))
            let initiallyActive = activated()
            attach(
                "target=\(name) savedPoint=\(point) window=\(window.frame) targetFrame=\(targetFrame) "
                    + "validPoint=\(pointValid) initiallyActive=\(initiallyActive)",
                phase: "delivery",
                to: activity
            )
            guard pointValid, !initiallyActive else {
                attach("No gesture delivered: invalid restored point or action already active", phase: "outcome", to: activity)
                return
            }
            // Do not consult isHittable: its failed result is what this gesture diagnoses.
            let origin = window.coordinate(withNormalizedOffset: .zero)
            let coordinate = origin.withOffset(CGVector(
                dx: point.x - window.frame.minX, dy: point.y - window.frame.minY
            ))
            coordinate.tap()
            let didActivate = waitUntil(timeout: Self.restorationObservationDuration) { activated() }
            attach("delivered=true activated=\(didActivate)", phase: "outcome", to: activity)
            for attachment in Self.failureAttachments(in: app, name: diagnosticName, phase: "after") { activity.add(attachment) }
        }
    }

    private static func failureAttachments(in app: XCUIApplication, name: String, phase: String) -> [XCTAttachment] {
        let attachments = [
            ("\(phase)-native.txt", XCTAttachment(string: nativeReport(in: app))),
            ("\(phase)-hierarchy.txt", XCTAttachment(string: app.debugDescription)),
            (phase, XCTAttachment(screenshot: XCUIScreen.main.screenshot()))
        ]
        return attachments.map { suffix, attachment in
            attachment.name = "\(name)-\(suffix)"
            attachment.lifetime = .keepAlways
            return attachment
        }
    }

    private static func nativeReport(in app: XCUIApplication) -> String {
        let reports = ["ipad.detail.panel", "ipad.sidebar.panel"].map { identifier in
            let probes = app.otherElements.matching(identifier: "\(identifier).geometry")
            guard probes.count == 1 else { return "\(identifier): probeCount=\(probes.count)" }
            let probe = probes.firstMatch
            return "\(identifier) geometry=\(probe.value as? String ?? "missing") native=\(probe.label)"
        }
        return reports.joined(separator: "\n")
    }

    static func paneFrame(_ identifier: String, in app: XCUIApplication) throws -> CGRect {
        let probes = app.otherElements.matching(identifier: "\(identifier).geometry")
        XCTAssertTrue(probes.firstMatch.waitForExistence(timeout: timeout))
        XCTAssertEqual(probes.count, 1, "The pane must have exactly one independent geometry probe")
        let probe = probes.firstMatch
        XCTAssertLessThanOrEqual(probe.frame.width, 1, "The diagnostic marker must not cover pane controls")
        XCTAssertLessThanOrEqual(probe.frame.height, 1, "The diagnostic marker must not cover pane controls")
        let value = try XCTUnwrap(probe.value as? String)
        let data = try XCTUnwrap(value.data(using: .utf8))
        let report = try JSONDecoder().decode([String: Double].self, from: data)
        let frame = try CGRect(
            x: XCTUnwrap(report["x"]),
            y: XCTUnwrap(report["y"]),
            width: XCTUnwrap(report["width"]),
            height: XCTUnwrap(report["height"])
        )
        XCTContext.runActivity(named: "Measure \(identifier)") { activity in
            let attachment = XCTAttachment(string: value)
            attachment.name = "\(identifier)-geometry.json"
            attachment.lifetime = .keepAlways
            activity.add(attachment)
        }
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
