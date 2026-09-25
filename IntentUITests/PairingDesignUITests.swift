import XCTest

/// Exercises the real Connect buttons with the existing ephemeral demo store.
/// Never enters credentials, scans a code, or attempts a live connection.
nonisolated final class PairingDesignUITests: XCTestCase {
    private static let timeout: TimeInterval = 15

    @MainActor
    func testReferencePlacementMatchesFigma() throws {
        let app = try launchAtHome()
        let saved = option("Saved Connections", in: app)
        XCTAssertTrue(saved.waitForExistence(timeout: Self.timeout))
        guard app.frame.size == CGSize(width: 402, height: 874) else {
            throw XCTSkip("The supplied Figma reference is 402×874; run on iPhone 16 Pro at normal text size")
        }
        // Native Inter line boxes extend equally above/below the cap-to-baseline box.
        // Compare text centers, not their deliberately untrimmed accessibility bounds.
        XCTAssertEqual(app.staticTexts["Connect to Intent"].frame.midY, 233, accuracy: 1.5)
        let description = app.staticTexts["Pair with your desktop app to manage workspaces and chat with agents."]
        XCTAssertEqual(description.frame.midY, 283.5, accuracy: 1.5)
        XCTAssertEqual(option("Scan QR Code", in: app).frame.minY, 364, accuracy: 1.5)
        XCTAssertEqual(option("Manual Connection", in: app).frame.minY, 500, accuracy: 1.5)
        XCTAssertEqual(saved.frame.minY, 588, accuracy: 1.5)
        for (title, subtitle, centerY) in [
            ("Scan QR Code", "Fastest way to connect", 420.0),
            ("Manual Connection", "Enter IP, port, and token", 532.0),
            ("Saved Connections", "Reconnect to paired daemon", 620.0)
        ] {
            // Each trimmed 12-point line sits on either side of the 12-point gap.
            XCTAssertEqual(app.staticTexts[title].frame.midY, centerY - 12, accuracy: 1.5)
            XCTAssertEqual(app.staticTexts[subtitle].frame.midY, centerY + 12, accuracy: 1.5)
        }
        capture(app, named: "reference-placement")
    }

    @MainActor
    func testConnectActionsAndConditionalSavedRow() throws {
        continueAfterFailure = false
        let app = try launchAtHome()

        let saved = option("Saved Connections", in: app)
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
        XCTAssertTrue(app.staticTexts["Point at the QR code in Intent Settings"].waitForExistence(timeout: Self.timeout))
        capture(app, named: "scanner-sheet")
        app.buttons["Cancel"].tap()
        XCTAssertTrue(saved.waitForExistence(timeout: Self.timeout))

        saved.tap()
        XCTAssertTrue(app.staticTexts["saved-connections.title"].waitForExistence(timeout: Self.timeout))
        let machine = option("Demo Mac", in: app)
        XCTAssertTrue(machine.waitForExistence(timeout: Self.timeout))
        XCTAssertFalse(app.staticTexts["Pair New"].exists)
        XCTAssertFalse(app.staticTexts["Connected"].exists, "Home is unbound; another window must not lend its badge")
        XCTAssertEqual(machine.frame.height, 96, accuracy: 0.5)
        XCTAssertEqual(machine.frame.minX, 24, accuracy: 0.5)
        XCTAssertEqual(machine.frame.width, app.frame.width - 48, accuracy: 0.5)
        capture(app, named: "saved-sheet")
        machine.press(forDuration: 1)
        app.buttons["Connection Details"].tap()
        XCTAssertTrue(app.staticTexts["saved-connection.details-title"].waitForExistence(timeout: Self.timeout))
        XCTAssertTrue(app.staticTexts["demo.invalid:443"].exists)
        app.buttons["connection-sheet.close"].tap()
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
    private func verifySavedConnectionDeletion(
        _ machine: XCUIElement,
        in app: XCUIApplication,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertTrue(machine.waitForExistence(timeout: Self.timeout), file: file, line: line)
        machine.press(forDuration: 1)
        app.buttons["Delete"].tap()
        let confirmation = app.alerts["Delete Connection?"]
        XCTAssertTrue(confirmation.waitForExistence(timeout: Self.timeout), file: file, line: line)
        confirmation.buttons["Cancel"].tap()
        XCTAssertTrue(
            machine.waitForExistence(timeout: Self.timeout), "Cancel must keep the saved connection", file: file, line: line
        )
        machine.press(forDuration: 1)
        app.buttons["Delete"].tap()
        XCTAssertTrue(confirmation.waitForExistence(timeout: Self.timeout), file: file, line: line)
        confirmation.buttons["Delete"].tap()
        XCTAssertTrue(machine.waitForNonExistence(timeout: Self.timeout), file: file, line: line)
        XCTAssertTrue(app.staticTexts["saved-connections.empty"].exists, file: file, line: line)
    }

    @MainActor
    private func launchAtHome() throws -> XCUIApplication {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: directory) }
        let app = XCUIApplication()
        app.launchArguments = ["--demo-data", "--demo-connection-loss-directory=" + directory.path]
        app.launch()
        XCTAssertTrue(app.buttons["Workspace options"].waitForExistence(timeout: Self.timeout))
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
