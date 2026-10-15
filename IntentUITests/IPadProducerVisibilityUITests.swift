import XCTest

/// Temporary discriminator: hidden snapshots are observations, not presumed fixes.
nonisolated final class IPadProducerVisibilityUITests: XCTestCase {
    private static let timeout: TimeInterval = 15
    private static let identifiers = [
        "visibility.sidebar", "visibility.detail", "visibility.list", "visibility.row",
        "visibility.list.header", "visibility.content.header", "composer.textView", "visibility.standalone",
        "visibility.action", "visibility.action.count"
    ]

    override func setUpWithError() throws {
        try super.setUpWithError()
        continueAfterFailure = false
    }

    override func tearDownWithError() throws {
        continueAfterFailure = true
        try super.tearDownWithError()
    }

    @MainActor func testRetainedProducerHidingComparison() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad, "The retained pane discriminator requires iPad")
        let app = XCUIApplication()
        app.launchArguments += ["--demo-data", "--demo-ipad-producer-visibility"]
        app.launch()
        addTeardownBlock { @MainActor [self] () async throws in
            defer { app.terminate() }
            let probe = app.descendants(matching: .any)["visibility.native"].firstMatch
            let native = probe.exists ? (try? nativeReport(probe)) ?? [:] : [:]
            try capture(app, phase: "final", native: native)
        }
        let editor = app.textViews["composer.textView"]
        XCTAssertTrue(editor.wait(for: \.isHittable, toEqual: true, timeout: Self.timeout))
        editor.tap()
        editor.typeText(" typed")
        let draft = try XCTUnwrap(editor.value as? String)
        XCTAssertTrue(draft.contains("typed"))
        app.buttons["visibility.prepare"].tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: Self.timeout))
        var original: [String: String] = [:]
        for phase in ["visible", "outerHidden", "outerRestored", "producerHidden", "producerRestored"] {
            if phase != "visible" { app.buttons["visibility.next"].tap() }
            let probe = app.descendants(matching: .any)["visibility.native"].firstMatch
            XCTAssertTrue(probe.wait(for: \.label, toEqual: phase, timeout: Self.timeout))
            let native = try nativeReport(probe)
            try capture(app, phase: phase, native: native)
            if original.isEmpty { original = native }
            XCTAssertEqual(native["editorCount"], "1")
            XCTAssertEqual(native["retained"], "true")
            XCTAssertEqual(native["editor"], original["editor"])
            XCTAssertEqual(native["draft"], draft)
            XCTAssertEqual(native["selection"], original["originalSelection"])
            if phase == "visible" || phase.hasSuffix("Restored") { verifyVisible(app, draft: draft) }
        }
    }

    @MainActor private func verifyVisible(_ app: XCUIApplication, draft: String) {
        for identifier in Self.identifiers {
            let matches = elements(in: app, identifier: identifier)
            let element = matches.firstMatch
            XCTAssertTrue(element.waitForExistence(timeout: Self.timeout), "Missing visible sentinel: \(identifier)")
            XCTAssertEqual(matches.count, 1, "Ambiguous visible sentinel: \(identifier)")
            XCTAssertTrue(element.wait(for: \.isHittable, toEqual: true, timeout: Self.timeout), "Unreachable visible sentinel: \(identifier)")
        }
        let list = elements(in: app, identifier: "visibility.list").firstMatch
        XCTAssertTrue(list.staticTexts["visibility.row"].exists)
        XCTAssertTrue(list.staticTexts["visibility.list.header"].exists)
        XCTAssertEqual(app.textViews["composer.textView"].value as? String, draft)
    }

    @MainActor private func elements(in app: XCUIApplication, identifier: String) -> XCUIElementQuery {
        if identifier == "visibility.list" {
            // SwiftUI can apply the pane identifier to its native collection view.
            return app.collectionViews.matching(NSPredicate(format: "identifier IN %@", ["visibility.list", "visibility.sidebar"]))
        }
        return app.descendants(matching: .any).matching(identifier: identifier)
    }

    @MainActor private func nativeReport(_ probe: XCUIElement) throws -> [String: String] {
        let value = try XCTUnwrap(probe.value as? String)
        let data = try XCTUnwrap(value.data(using: .utf8))
        return try JSONDecoder().decode([String: String].self, from: data)
    }

    @MainActor private func capture(_ app: XCUIApplication, phase: String, native: [String: String]) throws {
        let observations: [[String: Any]] = Self.identifiers.map { identifier in
            let matches = elements(in: app, identifier: identifier)
            let element = matches.firstMatch
            let exists = element.exists
            return [
                "identifier": identifier, "count": matches.count, "exists": exists,
                "nativeIdentifier": exists ? element.identifier : "absent",
                "hittable": exists && element.isHittable,
                "frame": exists ? String(describing: element.frame) : "absent"
            ]
        }
        let data = try JSONSerialization.data(withJSONObject: ["phase": phase, "native": native, "elements": observations], options: [.sortedKeys])
        let json = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        json.name = "ipad-producer-ui-\(phase).json"
        json.lifetime = .keepAlways
        add(json)
        let hierarchy = XCTAttachment(string: app.debugDescription)
        hierarchy.name = "ipad-producer-ui-\(phase)-hierarchy.txt"
        hierarchy.lifetime = .keepAlways
        add(hierarchy)
    }
}

extension IPadProducerVisibilityUITests {
    private enum Interaction {
        static let settleDuration: TimeInterval = 0.3
        static let pressDuration: TimeInterval = 0.05
        static let upperFraction: CGFloat = 0.25
        static let lowerFraction: CGFloat = 0.75
        static let minimumScrollDistance = 40.0
        static let maximumReturnDrags = 3
    }

    private struct ListGestures {
        let frame: CGRect
        let tap: XCUICoordinate
        let upper: XCUICoordinate
        let lower: XCUICoordinate

        @MainActor func dragUp() {
            lower.press(forDuration: Interaction.pressDuration, thenDragTo: upper, withVelocity: .slow, thenHoldForDuration: 0.5)
        }

        @MainActor func dragDown() {
            upper.press(forDuration: Interaction.pressDuration, thenDragTo: lower, withVelocity: .slow, thenHoldForDuration: 0.5)
        }
    }

    @MainActor func testRetainedListRejectsCoveredInteraction() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad, "The retained List interaction test requires iPad")
        let app = try prepareInteractionApp()
        let probe = app.descendants(matching: .any)["visibility.native"].firstMatch
        let original = try settledReport(probe)
        XCTAssertEqual(original["listCount"], "1")
        XCTAssertEqual(original["list"], original["originalList"])
        XCTAssertGreaterThan(try number(original, "listMaximumY") - number(original, "listMinimumY"), try number(original, "listHeight"))
        let gestures = captureListGestures(app)
        for phase in ["visible", "outerHidden", "outerRestored", "producerHidden", "producerRestored"] {
            if phase != "visible" { app.buttons["visibility.next"].tap() }
            XCTAssertTrue(probe.wait(for: \.label, toEqual: phase, timeout: Self.timeout))
            let before = try settledReport(probe)
            assertRetained(before, original: original)
            XCTAssertEqual(elements(in: app, identifier: "visibility.list").firstMatch.frame, gestures.frame)
            try capture(app, phase: "interaction-\(phase)-before", native: before)
            if phase.hasSuffix("Hidden") {
                try verifyBlockedInteraction(app, probe: probe, gestures: gestures, original: original, before: before)
            } else {
                try verifyActiveInteraction(app, probe: probe, gestures: gestures, original: original, before: before)
            }
            assertRetained(try settledReport(probe), original: original)
        }
    }

    @MainActor private func prepareInteractionApp() throws -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["--demo-data", "--demo-ipad-producer-visibility"]
        app.launch()
        addTeardownBlock { @MainActor [self] () async throws in
            defer { app.terminate() }
            let probe = app.descendants(matching: .any)["visibility.native"].firstMatch
            try capture(app, phase: "interaction-final", native: probe.exists ? (try? nativeReport(probe)) ?? [:] : [:])
        }
        let editor = app.textViews["composer.textView"]
        XCTAssertTrue(editor.wait(for: \.isHittable, toEqual: true, timeout: Self.timeout))
        editor.tap()
        editor.typeText(" typed")
        XCTAssertTrue(try XCTUnwrap(editor.value as? String).contains("typed"))
        app.buttons["visibility.prepare"].tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: Self.timeout))
        let probe = app.descendants(matching: .any)["visibility.native"].firstMatch
        XCTAssertTrue(probe.wait(for: \.label, toEqual: "visible", timeout: Self.timeout))
        return app
    }

    @MainActor private func captureListGestures(_ app: XCUIApplication) -> ListGestures {
        let lists = elements(in: app, identifier: "visibility.list")
        XCTAssertEqual(lists.count, 1)
        let frame = lists.firstMatch.frame
        let action = app.buttons["visibility.action"]
        XCTAssertTrue(action.waitForExistence(timeout: Self.timeout))
        let actionFrame = action.frame
        XCTAssertFalse(actionFrame.isEmpty)
        XCTAssertTrue(frame.contains(actionFrame))
        let window = app.windows.firstMatch
        let origin = window.coordinate(withNormalizedOffset: .zero)
        let left = window.frame.minX
        let top = window.frame.minY
        return ListGestures(
            frame: frame,
            tap: origin.withOffset(CGVector(dx: actionFrame.midX - left, dy: actionFrame.midY - top)),
            upper: origin.withOffset(CGVector(dx: frame.midX - left, dy: frame.minY + frame.height * Interaction.upperFraction - top)),
            lower: origin.withOffset(CGVector(dx: frame.midX - left, dy: frame.minY + frame.height * Interaction.lowerFraction - top))
        )
    }

    @MainActor private func settledReport(_ probe: XCUIElement) throws -> [String: String] {
        var previous: [String: String] = [:]
        var stableSince = Date()
        let settled = waitUntil(timeout: Self.timeout) {
            guard let current = try? self.nativeReport(probe), current["listCount"] == "1", current["listIdle"] == "true" else {
                previous = [:]
                stableSince = Date()
                return false
            }
            if current != previous {
                previous = current
                stableSince = Date()
            }
            return Date().timeIntervalSince(stableSince) >= Interaction.settleDuration
        }
        XCTAssertTrue(settled, "Native List must be unique, idle and stable before comparing state")
        return try nativeReport(probe)
    }

    @MainActor private func number(_ report: [String: String], _ key: String) throws -> Double {
        try XCTUnwrap(Double(try XCTUnwrap(report[key], "Missing native \(key)")))
    }

    @MainActor private func assertRetained(_ report: [String: String], original: [String: String]) {
        XCTAssertEqual(report["listCount"], "1")
        XCTAssertEqual(report["list"], original["originalList"])
        XCTAssertEqual(report["editorCount"], "1")
        XCTAssertEqual(report["retained"], "true")
        XCTAssertEqual(report["editor"], original["originalEditor"])
        XCTAssertEqual(report["draft"], original["originalDraft"])
        XCTAssertEqual(report["selection"], original["originalSelection"])
    }

    @MainActor private func verifyBlockedInteraction(
        _ app: XCUIApplication,
        probe: XCUIElement,
        gestures: ListGestures,
        original: [String: String],
        before: [String: String]
    ) throws {
        XCTAssertEqual(before["gateInteractive"], "false")
        XCTAssertEqual(before["gateChildrenHidden"], "true")
        gestures.tap.tap()
        try verifyUnchangedInteraction(app, probe: probe, original: original, before: before, gesture: "tap")
        gestures.dragUp()
        try verifyUnchangedInteraction(app, probe: probe, original: original, before: before, gesture: "drag")
    }

    @MainActor private func verifyUnchangedInteraction(
        _ app: XCUIApplication,
        probe: XCUIElement,
        original: [String: String],
        before: [String: String],
        gesture: String
    ) throws {
        let after = try settledReport(probe)
        try capture(app, phase: "interaction-\(probe.label)-\(gesture)", native: after)
        assertRetained(after, original: original)
        for key in ["actionCount", "listOffsetX", "listOffsetY"] {
            XCTAssertEqual(after[key], before[key], "Covered List changed \(key) after a coordinate \(gesture)")
        }
    }

    @MainActor private func verifyActiveInteraction(
        _ app: XCUIApplication,
        probe: XCUIElement,
        gestures: ListGestures,
        original: [String: String],
        before: [String: String]
    ) throws {
        XCTAssertEqual(before["gateInteractive"], "true")
        XCTAssertEqual(before["gateChildrenHidden"], "false")
        XCTAssertEqual(try number(before, "listOffsetY"), try number(before, "listMinimumY"), accuracy: 1)
        gestures.tap.tap()
        let tapped = try settledReport(probe)
        try capture(app, phase: "interaction-\(probe.label)-tap", native: tapped)
        XCTAssertEqual(try number(tapped, "actionCount"), try number(before, "actionCount") + 1)
        assertRetained(tapped, original: original)
        gestures.dragUp()
        let scrolled = try settledReport(probe)
        try capture(app, phase: "interaction-\(probe.label)-drag", native: scrolled)
        XCTAssertGreaterThan(try number(scrolled, "listOffsetY") - number(tapped, "listOffsetY"), Interaction.minimumScrollDistance)
        XCTAssertEqual(scrolled["actionCount"], tapped["actionCount"])
        assertRetained(scrolled, original: original)
        try returnListToTop(app, probe: probe, gestures: gestures, original: original)
    }

    @MainActor private func returnListToTop(
        _ app: XCUIApplication, probe: XCUIElement, gestures: ListGestures, original: [String: String]
    ) throws {
        var restored = try settledReport(probe)
        let actionCount = restored["actionCount"]
        for _ in 0..<Interaction.maximumReturnDrags {
            gestures.dragDown()
            restored = try settledReport(probe)
            if abs(try number(restored, "listOffsetY") - number(restored, "listMinimumY")) <= 1 { break }
        }
        try capture(app, phase: "interaction-\(probe.label)-top", native: restored)
        XCTAssertEqual(try number(restored, "listOffsetY"), try number(restored, "listMinimumY"), accuracy: 1)
        XCTAssertEqual(restored["actionCount"], actionCount)
        assertRetained(restored, original: original)
    }
}
