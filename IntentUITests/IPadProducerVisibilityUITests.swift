import XCTest

/// Temporary discriminator: hidden snapshots are observations, not presumed fixes.
nonisolated final class IPadProducerVisibilityUITests: XCTestCase {
    private static let timeout: TimeInterval = 15
    private static let identifiers = [
        "visibility.sidebar", "visibility.detail", "visibility.list", "visibility.row",
        "visibility.list.header", "visibility.content.header", "composer.textView"
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
