import XCTest

/// Exercises the real Connect buttons with the existing ephemeral demo store.
/// Never enters credentials, scans a code, or attempts a live connection.
nonisolated final class PairingDesignUITests: XCTestCase {
    private static let timeout: TimeInterval = 15
    private static let scannerUnavailable = "Camera scanning isn't available — use manual token entry instead"

    @MainActor
    func testSavedConnectionActionsPreserveCurrentConnection() throws {
        let app = try launchConnected()
        try verifyBoundConnectionActions(in: app)
        app.buttons["intent.menu.connections"].tap()
        let scan = app.buttons["saved-connections.scan"]
        let manual = app.buttons["saved-connections.manual"]
        XCTAssertTrue(manual.waitForExistence(timeout: Self.timeout))
        XCTAssertEqual(scan.label, "Scan QR Code")
        XCTAssertEqual(manual.label, "Manual Connection")
        for row in [scan, manual] {
            XCTAssertGreaterThanOrEqual(row.frame.height, 44)
            XCTAssertLessThanOrEqual(row.frame.height, 60, "Normal text should use a compact single-title row")
        }
        XCTAssertEqual(scan.frame.height, manual.frame.height, accuracy: 1)
        XCTAssertEqual(scan.frame.width, manual.frame.width, accuracy: 1)
        XCTAssertEqual(scan.frame.maxY, manual.frame.minY, accuracy: 1, "Rows share one card with only a thin divider")
        let heading = app.staticTexts["Add Connection"]
        XCTAssertEqual(heading.frame.minX, scan.frame.minX, accuracy: 1)
        XCTAssertLessThan(heading.frame.height, app.staticTexts["Scan QR Code"].frame.height)
        capture(app, named: "populated-compact-actions")
    }

    @MainActor
    func testSavedConnectionActionsAtAccessibilityTextSize() throws {
        let app = try launchConnected(arguments: [
            "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"
        ])
        try verifyBoundConnectionActions(in: app)
    }

    @MainActor
    func testSavedConnectionActionsRemainAvailableWhenEmpty() throws {
        continueAfterFailure = false
        let app = try launchAtHome()
        let saved = app.buttons["pairing.saved-connections"]
        XCTAssertTrue(saved.waitForExistence(timeout: Self.timeout))
        saved.tap()
        verifySavedConnectionDeletion(option("Demo Mac", in: app), in: app)
        try verifyDirectConnectionActions(in: app)
        XCTAssertTrue(app.staticTexts["saved-connections.empty"].exists)
        XCTAssertFalse(option("Demo Mac", in: app).exists)
        capture(app, named: "empty-direct-actions")
        app.buttons["connection-sheet.close"].tap()
        XCTAssertTrue(option("Manual Connection", in: app).waitForExistence(timeout: Self.timeout))
        XCTAssertFalse(saved.exists)
    }

    @MainActor
    func testConnectActionsAndConditionalSavedRow() throws {
        continueAfterFailure = false
        let app = try launchAtHome()

        let saved = app.buttons["pairing.saved-connections"]
        let manual = option("Manual Connection", in: app)
        let scan = option("Scan QR Code", in: app)
        XCTAssertTrue(saved.waitForExistence(timeout: Self.timeout))
        XCTAssertTrue(scan.isHittable)
        XCTAssertTrue(manual.isHittable)
        XCTAssertTrue(saved.isHittable)
        XCTAssertLessThan(scan.frame.maxY, manual.frame.minY)
        XCTAssertLessThan(manual.frame.maxY, saved.frame.minY)
        capture(app, named: "saved-on")

        manual.tap()
        XCTAssertTrue(app.staticTexts["manual.title"].waitForExistence(timeout: Self.timeout))
        XCTAssertTrue(app.textFields["manual.host"].exists)
        capture(app, named: "manual-sheet")
        app.buttons["connection-sheet.close"].tap()
        XCTAssertTrue(saved.waitForExistence(timeout: Self.timeout))

        scan.tap()
        XCTAssertTrue(app.staticTexts[Self.scannerUnavailable].waitForExistence(timeout: Self.timeout))
        XCTAssertFalse(app.staticTexts["Point at the QR code in the Intent Settings"].exists)
        XCTAssertTrue(app.buttons["Cancel"].isHittable)
        capture(app, named: "scanner-full-screen")
        app.buttons["Cancel"].tap()
        XCTAssertTrue(saved.waitForExistence(timeout: Self.timeout))

        saved.tap()
        XCTAssertTrue(app.staticTexts["saved-connections.title"].waitForExistence(timeout: Self.timeout))
        let machine = option("Demo Mac", in: app)
        XCTAssertTrue(machine.waitForExistence(timeout: Self.timeout))
        XCTAssertFalse(app.staticTexts["Pair New"].exists)
        XCTAssertFalse(app.staticTexts["Connected"].exists, "Home is unbound; another window must not lend its badge")
        XCTAssertTrue(machine.isHittable)
        XCTAssertGreaterThanOrEqual(machine.frame.height, 44)
        verifySavedCardGeometry(machine, in: app)
        capture(app, named: "saved-sheet")
        machine.press(forDuration: 1)
        app.buttons["Connection Details"].tap()
        XCTAssertTrue(app.staticTexts["saved-connection.details-title"].waitForExistence(timeout: Self.timeout))
        XCTAssertTrue(app.staticTexts["demo.invalid:443"].exists)
        try closePresentedSheet(in: app)
        XCTAssertTrue(app.staticTexts["saved-connection.details-title"].waitForNonExistence(timeout: Self.timeout))
        app.buttons["connection-sheet.close"].tap()
        XCTAssertTrue(saved.waitForExistence(timeout: Self.timeout))

        // Remove only this test's in-memory fixture through the real saved sheet.
        saved.tap()
        verifySavedConnectionDeletion(machine, in: app)
        app.buttons["connection-sheet.close"].tap()
        XCTAssertTrue(manual.waitForExistence(timeout: Self.timeout))
        XCTAssertTrue(scan.isHittable)
        XCTAssertFalse(saved.exists)
        capture(app, named: "saved-off")
    }

    @MainActor
    private func verifySavedCardGeometry(_ machine: XCUIElement, in app: XCUIApplication) {
        let appWidth = app.frame.width
        XCTAssertGreaterThan(appWidth, 0)
        XCTAssertFalse(machine.identifier.isEmpty)
        let sheet = app.scrollViews.containing(.button, identifier: machine.identifier).firstMatch
        XCTAssertTrue(sheet.waitForExistence(timeout: Self.timeout))
        let sheetFrame = sheet.frame
        // iOS 26 floating sheets stay scaled after presentation. Recover layout
        // coordinates from the scroll container, never from the card under test.
        let scale = sheetFrame.width / appWidth
        XCTAssertGreaterThanOrEqual(scale, 0.9)
        XCTAssertLessThanOrEqual(scale, 1)
        let cardFrame = machine.frame
        XCTAssertEqual(cardFrame.height / scale, 96, accuracy: 0.5)
        XCTAssertEqual((cardFrame.minX - sheetFrame.minX) / scale, 24, accuracy: 0.5)
        XCTAssertEqual(cardFrame.width / scale, appWidth - 48, accuracy: 0.5)
    }

    @MainActor
    private func verifySavedConnectionDeletion(
        _ machine: XCUIElement,
        in app: XCUIApplication,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertTrue(machine.waitForExistence(timeout: Self.timeout), file: file, line: line)
        machine.press(forDuration: 1)
        let remove = app.buttons["Remove Connection"]
        XCTAssertTrue(remove.waitForExistence(timeout: Self.timeout), file: file, line: line)
        remove.tap()
        let confirmation = app.alerts["Remove Connection?"]
        XCTAssertTrue(confirmation.waitForExistence(timeout: Self.timeout), file: file, line: line)
        confirmation.buttons["Cancel"].tap()
        XCTAssertTrue(
            machine.waitForExistence(timeout: Self.timeout), "Cancel must keep the saved connection", file: file, line: line
        )
        machine.press(forDuration: 1)
        XCTAssertTrue(remove.waitForExistence(timeout: Self.timeout), file: file, line: line)
        remove.tap()
        XCTAssertTrue(confirmation.waitForExistence(timeout: Self.timeout), file: file, line: line)
        confirmation.buttons["Remove"].tap()
        XCTAssertTrue(machine.waitForNonExistence(timeout: Self.timeout), file: file, line: line)
        XCTAssertTrue(app.staticTexts["saved-connections.empty"].exists, file: file, line: line)
    }

    @MainActor
    private func launchConnected(arguments: [String] = [], directory: URL? = nil) throws -> XCUIApplication {
        continueAfterFailure = false
        let directory = try directory ?? makeDemoDirectory()
        let app = XCUIApplication()
        app.launchArguments = ["--demo-data", "--demo-connection-loss-directory=" + directory.path] + arguments
        app.launch()
        XCTAssertTrue(app.buttons["intent.menu.open"].waitForExistence(timeout: Self.timeout))
        return app
    }

    @MainActor
    private func verifyBoundConnectionActions(in app: XCUIApplication) throws {
        app.openHomeAction("connections")
        let machine = option("Demo Mac", in: app)
        XCTAssertTrue(machine.waitForExistence(timeout: Self.timeout))
        // Select the fixture through the real row before asserting window ownership.
        // A restored demo scene may initially be unbound (ios#515).
        machine.tap()
        XCTAssertTrue(app.staticTexts["saved-connections.title"].waitForNonExistence(timeout: Self.timeout))
        app.openHomeAction("connections")
        XCTAssertTrue(machine.waitForExistence(timeout: Self.timeout))
        let originalIdentifier = machine.identifier
        XCTAssertTrue(app.staticTexts["Connected"].exists)
        try verifyDirectConnectionActions(in: app)
        XCTAssertEqual(machine.identifier, originalIdentifier, "Cancel must preserve the saved connection")
        XCTAssertTrue(app.staticTexts["Connected"].exists, "Cancel must preserve this window's binding")
        reveal(machine, in: app, scrollingUp: false)
        machine.tap()
        XCTAssertTrue(app.staticTexts["saved-connections.title"].waitForNonExistence(timeout: Self.timeout))
        app.buttons["intent.menu.open"].tap()
        XCTAssertTrue(app.revealHomeAction("connections").isHittable)
    }

    @MainActor
    private func verifyDirectConnectionActions(in app: XCUIApplication) throws {
        let heading = app.staticTexts["Add Connection"]
        XCTAssertTrue(heading.waitForExistence(timeout: Self.timeout))
        XCTAssertFalse(app.buttons["Add Connection"].exists, "Add Connection must be a heading, not a chooser")
        for (identifier, destination, closeIdentifier) in [
            ("saved-connections.scan", Self.scannerUnavailable, "Cancel"),
            ("saved-connections.manual", "manual.title", "connection-sheet.close")
        ] {
            let action = app.buttons[identifier]
            XCTAssertTrue(action.waitForExistence(timeout: Self.timeout))
            reveal(action, in: app)
            XCTAssertTrue(action.isHittable)
            XCTAssertGreaterThanOrEqual(action.frame.height, 44)
            capture(app, named: identifier)
            action.tap()
            let title = app.staticTexts[destination]
            XCTAssertTrue(title.waitForExistence(timeout: Self.timeout), "One tap must open the destination")
            capture(app, named: identifier + "-destination")
            try closePresentedSheet(in: app, identifier: closeIdentifier)
            XCTAssertTrue(title.waitForNonExistence(timeout: Self.timeout))
            XCTAssertTrue(app.staticTexts["saved-connections.title"].exists, "Cancel must return to Saved Connections")
            XCTAssertTrue(heading.exists)
        }
    }

    @MainActor
    private func closePresentedSheet(in app: XCUIApplication, identifier: String = "connection-sheet.close") throws {
        // Nested native sheets both expose Close; only the top sheet is interactive (ios#482).
        let close = try XCTUnwrap(app.buttons.matching(identifier: identifier)
            .allElementsBoundByIndex.first { $0.isHittable })
        close.tap()
    }

    @MainActor
    private func reveal(_ element: XCUIElement, in app: XCUIApplication, scrollingUp: Bool = true) {
        for _ in 0..<5 {
            if element.isHittable { break }
            let scroll = app.scrollViews.firstMatch
            if scrollingUp { scroll.swipeUp() } else { scroll.swipeDown() }
        }
    }

    @MainActor
    private func makeDemoDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: directory) }
        return directory
    }

    @MainActor
    private func launchAtHome() throws -> XCUIApplication {
        let directory = try makeDemoDirectory()
        let app = try launchConnected(directory: directory)
        try Data().write(to: directory.appendingPathComponent("loss"))
        let home = app.buttons["connection-loss.home"]
        XCTAssertTrue(home.waitForExistence(timeout: Self.timeout))
        home.tap()
        return app
    }

    @MainActor
    private func option(_ title: String, in app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", title)).firstMatch
    }

    @MainActor
    private func capture(_ app: XCUIApplication, named name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "connect-design-" + name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
