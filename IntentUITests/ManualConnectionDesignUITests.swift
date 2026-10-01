import XCTest

/// Real native-sheet/editor boundaries; synthetic draft only, no live pairing.
nonisolated final class ManualConnectionDesignUITests: XCTestCase {
    private static let timeout: TimeInterval = 15

    @MainActor
    func testSavedBlocksBackgroundNavigationAndRestoresItAfterDismissal() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--demo-data"]
        app.launch()
        let search = app.buttons["workspaces.search.open"]
        XCTAssertTrue(search.waitForExistence(timeout: Self.timeout))
        let backgroundPoint = app.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: search.frame.midX, dy: search.frame.midY))
        openSaved(in: app)
        backgroundPoint.tap()
        XCTAssertFalse(app.textFields["workspaces.search.field"].exists, "The native modal shield must block search")
        capture(app, named: "saved-background-blocked")
        // The system may dismiss a short detent on a dimmer tap. It must not
        // deliver that same tap to search underneath, whether it dismisses or not.
        if !app.staticTexts["saved-connections.title"].exists { openSaved(in: app) }

        app.buttons["connection-sheet.close"].tap()
        XCTAssertTrue(app.staticTexts["saved-connections.title"].waitForNonExistence(timeout: Self.timeout))
        capture(app, named: "saved-close-cleanup")
        openSaved(in: app)
        let close = app.buttons["connection-sheet.close"].frame
        let origin = app.coordinate(withNormalizedOffset: .zero)
        let start = origin.withOffset(CGVector(dx: app.frame.midX, dy: close.minY))
        // A short, slow pull cancels rather than finishing interactive dismissal.
        let shortPull = origin.withOffset(CGVector(dx: app.frame.midX, dy: close.minY + 20))
        start.press(forDuration: 0.1, thenDragTo: shortPull, withVelocity: .slow, thenHoldForDuration: 0.5)
        XCTAssertTrue(app.staticTexts["saved-connections.title"].exists)
        XCTAssertFalse(app.textFields["workspaces.search.field"].exists)
        capture(app, named: "saved-cancelled-swipe")
        start.press(forDuration: 0.1, thenDragTo: origin.withOffset(
            CGVector(dx: app.frame.midX, dy: app.frame.maxY - 10)
        ))
        XCTAssertTrue(app.staticTexts["saved-connections.title"].waitForNonExistence(timeout: Self.timeout))
        capture(app, named: "saved-swipe-cleanup")
        search.tap()
        XCTAssertTrue(app.textFields["workspaces.search.field"].waitForExistence(timeout: Self.timeout))
    }

    @MainActor
    private func openSaved(in app: XCUIApplication) {
        app.openHomeAction("connections")
        XCTAssertTrue(app.staticTexts["saved-connections.title"].waitForExistence(timeout: Self.timeout))
    }

    @MainActor
    func testEmptyAndFilledReferencePlacement() throws {
        let app = try launchManual()
        guard app.frame.size == CGSize(width: 402, height: 874) else {
            throw XCTSkip("Figma comparison requires the 402×874 iPhone 16 Pro at normal text size")
        }
        assertReference(in: app)
        XCTAssertFalse(app.buttons["manual.connect"].isEnabled)
        XCTAssertEqual(app.textFields["manual.port"].value as? String, "5180")
        XCTAssertTrue(app.buttons["Paste API token"].exists)
        capture(app, named: "empty")

        app.textFields["manual.host"].tap()
        app.textFields["manual.host"].typeText("192.0.2.42")
        XCTAssertFalse(app.buttons["manual.connect"].isEnabled)
        let token = app.secureTextFields["manual.token"]
        let typed = "SYNTHETIC-NOT-A-CREDENTIAL"
        token.tap()
        token.typeText(typed)
        capture(app, named: "keyboard")
        app.buttons["Done"].tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: Self.timeout))
        XCTAssertEqual(token.value as? String, String(repeating: "•", count: typed.count))
        XCTAssertTrue(app.buttons["manual.connect"].isEnabled)
        XCTAssertFalse(app.buttons["Paste API token"].exists)
        assertReference(in: app)
        capture(app, named: "filled")
        app.buttons["connection-sheet.close"].tap()
        XCTAssertTrue(app.staticTexts["manual.title"].waitForNonExistence(timeout: Self.timeout))
    }

    @MainActor
    func testIncompleteFormAndInvalidPortRemainEditable() throws {
        let app = try launchManual()
        app.textFields["manual.host"].tap()
        app.textFields["manual.host"].typeText("draft.invalid")
        app.textFields["manual.port"].tap()
        app.textFields["manual.port"].typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 4))
        app.secureTextFields["manual.token"].tap()
        app.secureTextFields["manual.token"].typeText("SYNTHETIC-NOT-A-CREDENTIAL")
        app.buttons["Done"].tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: Self.timeout))
        // Existing semantics only gate host/token; malformed port is a submit error.
        XCTAssertTrue(app.buttons["manual.connect"].isEnabled)
        app.buttons["manual.connect"].tap()
        XCTAssertTrue(app.staticTexts["Invalid port number"].waitForExistence(timeout: Self.timeout))
        XCTAssertTrue(app.textFields["manual.host"].isEnabled)
        XCTAssertTrue(app.secureTextFields["manual.token"].isEnabled)
        capture(app, named: "invalid-port")
        app.buttons["connection-sheet.close"].tap()
        XCTAssertTrue(app.staticTexts["manual.title"].waitForNonExistence(timeout: Self.timeout))
    }

    @MainActor
    func testLargeTextKeepsFieldsAndCloseReachable() throws {
        let app = try launchManual(arguments: [
            "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"
        ])
        capture(app, named: "large-text-top")
        let host = app.textFields["manual.host"]
        scrollTo(host, in: app)
        host.tap()
        host.typeText("draft.invalid")
        let token = app.secureTextFields["manual.token"]
        scrollTo(token, in: app)
        token.tap()
        token.typeText("SYNTHETIC-NOT-A-CREDENTIAL")
        capture(app, named: "large-text-keyboard")
        app.buttons["Done"].tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: Self.timeout))
        let connect = app.buttons["manual.connect"]
        scrollTo(connect, in: app)
        XCTAssertTrue(connect.isEnabled)
        capture(app, named: "large-text-bottom")
        XCTAssertTrue(app.buttons["connection-sheet.close"].isHittable)
        app.buttons["connection-sheet.close"].tap()
        XCTAssertTrue(app.staticTexts["manual.title"].waitForNonExistence(timeout: Self.timeout))
    }

    @MainActor
    private func scrollTo(_ element: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<5 {
            if element.isHittable { break }
            // XCUITest's default swipe uses the full scroll frame, which extends
            // behind the keyboard. Drag the visible gutter, not the keyboard
            // or a focused text field's selection gesture.
            let scroll = app.scrollViews.firstMatch.frame.intersection(app.frame)
            let keyboardTop = app.keyboards.firstMatch.exists ? app.keyboards.firstMatch.frame.minY : app.frame.maxY
            let top = max(scroll.minY, app.buttons["connection-sheet.close"].frame.maxY)
            let bottom = min(scroll.maxY, keyboardTop)
            let origin = app.coordinate(withNormalizedOffset: .zero)
            let start = origin.withOffset(CGVector(dx: scroll.maxX - 12, dy: bottom - 24))
            let end = origin.withOffset(CGVector(dx: scroll.maxX - 12, dy: top + 24))
            start.press(forDuration: 0.1, thenDragTo: end)
        }
        XCTAssertTrue(element.isHittable)
    }

    @MainActor
    private func assertReference(in app: XCUIApplication) {
        let appFrame = app.frame
        let scroll = app.scrollViews.containing(.button, identifier: "manual.connect").firstMatch
        XCTAssertTrue(scroll.waitForExistence(timeout: Self.timeout))
        let scrollFrame = scroll.frame
        let scale = scrollFrame.width / appFrame.width
        XCTAssertGreaterThanOrEqual(scale, 0.9)
        XCTAssertLessThanOrEqual(scale, 1)
        XCTAssertTrue(appFrame.contains(scrollFrame))
        // Undo the native floating-sheet transform using its scroll container.
        // The reference sheet is unscaled and anchored to the screen bottom.
        func referenceFrame(_ element: XCUIElement) -> CGRect {
            let frame = element.frame
            return CGRect(
                x: (frame.minX - scrollFrame.minX) / scale,
                y: appFrame.maxY - (scrollFrame.maxY - frame.minY) / scale,
                width: frame.width / scale,
                height: frame.height / scale
            )
        }
        // Independent Figma coordinates, not production layout constants. Native
        // line boxes extend past cap edges, so compare centers for text/editors.
        let close = referenceFrame(app.buttons["connection-sheet.close"])
        XCTAssertEqual(close.minY, 231, accuracy: 1.5)
        XCTAssertEqual(close.minX, 24, accuracy: 0.5)
        XCTAssertEqual(referenceFrame(app.staticTexts["manual.title"]).midY, 325, accuracy: 1.5)
        XCTAssertEqual(referenceFrame(app.staticTexts["manual.subtitle"]).midY, 361, accuracy: 1.5)
        for (field, center) in [
            (app.textFields["manual.host"], 472.0),
            (app.textFields["manual.port"], 585.0),
            (app.secureTextFields["manual.token"], 698.0)
        ] {
            let frame = referenceFrame(field)
            XCTAssertEqual(frame.midY, center, accuracy: 1.5)
            XCTAssertEqual(frame.minX, 48, accuracy: 0.5)
        }
        let button = referenceFrame(app.buttons["manual.connect"])
        XCTAssertEqual(button.minY, 762, accuracy: 1.5)
        XCTAssertEqual(button.height, 64, accuracy: 0.5)
        XCTAssertEqual(button.width, 354, accuracy: 0.5)
    }

    @MainActor
    private func launchManual(arguments: [String] = []) throws -> XCUIApplication {
        continueAfterFailure = false
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: directory) }
        let app = XCUIApplication()
        app.launchArguments = ["--demo-data", "--demo-connection-loss-directory=" + directory.path] + arguments
        app.launch()
        XCTAssertTrue(app.buttons["intent.menu.open"].waitForExistence(timeout: Self.timeout))
        try Data().write(to: directory.appendingPathComponent("loss"))
        XCTAssertTrue(app.buttons["connection-loss.home"].waitForExistence(timeout: Self.timeout))
        app.buttons["connection-loss.home"].tap()
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Manual Connection")).firstMatch.tap()
        XCTAssertTrue(app.staticTexts["manual.title"].waitForExistence(timeout: Self.timeout))
        return app
    }

    @MainActor
    private func capture(_ app: XCUIApplication, named name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "manual-design-" + name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
