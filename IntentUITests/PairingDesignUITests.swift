import XCTest

nonisolated final class PairingDesignUITests: XCTestCase {
    private static let timeout: TimeInterval = 15
    private static let scannerUnavailable = "Camera scanning isn’t available — use manual token entry instead"

    @MainActor
    func testConnectActionsAndConditionalSavedRow() throws {
        continueAfterFailure = false
        let app = try launchAtHome()

        let saved = app.buttons["pairing.saved-connections"]
        let manual = option("Manual Connection", in: app)
        let scan = option("Scan QR Code", in: app)
        XCTAssertTrue(saved.appears(timeout: Self.timeout))
        XCTAssertTrue(scan.isHittable)
        XCTAssertTrue(manual.isHittable)
        XCTAssertTrue(saved.isHittable)
        XCTAssertLessThan(scan.frame.maxY, manual.frame.minY)
        XCTAssertLessThan(manual.frame.maxY, saved.frame.minY)
        capture(app, named: "saved-on")

        manual.tap()
        XCTAssertTrue(app.staticTexts["manual.title"].appears(timeout: Self.timeout))
        XCTAssertTrue(app.textFields["manual.host"].exists)
        capture(app, named: "manual-sheet")
        app.buttons["connection-sheet.close"].tap()
        XCTAssertTrue(saved.appears(timeout: Self.timeout))

        scan.tap()
        XCTAssertTrue(app.staticTexts[Self.scannerUnavailable].appears(timeout: Self.timeout))
        XCTAssertFalse(app.staticTexts["Find the QR code in Settings > Mobile\nin the Intent desktop app"].exists)
        XCTAssertTrue(app.buttons["Cancel"].isHittable)
        capture(app, named: "scanner-full-screen")
        app.buttons["Cancel"].tap()
        XCTAssertTrue(saved.appears(timeout: Self.timeout))

        saved.tap()
        XCTAssertTrue(app.staticTexts["saved-connections.title"].appears(timeout: Self.timeout))
        let machine = option("Demo Mac", in: app)
        XCTAssertTrue(machine.appears(timeout: Self.timeout))
        XCTAssertFalse(app.staticTexts["Pair New"].exists)
        XCTAssertFalse(app.staticTexts["Connected"].exists, "Home is unbound; another window must not lend its badge")
        XCTAssertTrue(machine.isHittable)
        XCTAssertGreaterThanOrEqual(machine.frame.height, 44)
        verifySavedCardGeometry(machine, in: app)
        capture(app, named: "saved-sheet")
        machine.press(forDuration: 1)
        app.buttons["Connection Details"].tap()
        XCTAssertTrue(app.staticTexts["saved-connection.details-title"].appears(timeout: Self.timeout))
        XCTAssertTrue(app.staticTexts["demo.invalid:443"].exists)
        try closePresentedSheet(in: app)
        XCTAssertTrue(app.staticTexts["saved-connection.details-title"].disappears(timeout: Self.timeout))
        app.buttons["connection-sheet.close"].tap()
        XCTAssertTrue(saved.appears(timeout: Self.timeout))

        saved.tap()
        verifySavedConnectionDeletion(machine, in: app)
        app.buttons["connection-sheet.close"].tap()
        XCTAssertTrue(manual.appears(timeout: Self.timeout))
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
        XCTAssertTrue(sheet.appears(timeout: Self.timeout))
        let sheetFrame = sheet.frame
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
        XCTAssertTrue(machine.appears(timeout: Self.timeout), file: file, line: line)
        machine.press(forDuration: 1)
        let remove = app.buttons["Remove Connection"]
        XCTAssertTrue(remove.appears(timeout: Self.timeout), file: file, line: line)
        remove.tap()
        let confirmation = app.alerts["Remove Connection?"]
        XCTAssertTrue(confirmation.appears(timeout: Self.timeout), file: file, line: line)
        confirmation.buttons["Cancel"].tap()
        XCTAssertTrue(
            machine.appears(timeout: Self.timeout), "Cancel must keep the saved connection", file: file, line: line
        )
        machine.press(forDuration: 1)
        XCTAssertTrue(remove.appears(timeout: Self.timeout), file: file, line: line)
        remove.tap()
        XCTAssertTrue(confirmation.appears(timeout: Self.timeout), file: file, line: line)
        confirmation.buttons["Remove"].tap()
        XCTAssertTrue(machine.disappears(timeout: Self.timeout), file: file, line: line)
        XCTAssertTrue(app.staticTexts["saved-connections.empty"].exists, file: file, line: line)
    }

    @MainActor
    private func launchConnected(arguments: [String] = [], directory: URL? = nil) throws -> XCUIApplication {
        continueAfterFailure = false
        let directory = try directory ?? makeDemoDirectory()
        let app = XCUIApplication.intent()
        app.launchArguments = ["--demo-data", "--demo-connection-loss-directory=" + directory.path] + arguments
        app.launch()
        XCTAssertTrue(app.buttons["intent.menu.open"].appears(timeout: Self.timeout))
        return app
    }

    @MainActor
    private func closePresentedSheet(in app: XCUIApplication, identifier: String = "connection-sheet.close") throws {
        let close = try XCTUnwrap(app.buttons.matching(identifier: identifier)
            .allElementsBoundByIndex.first { $0.isHittable })
        close.tap()
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
        let app = try launchConnected(arguments: ["--demo-connection-loss-stopped"], directory: directory)
        try Data().write(to: directory.appendingPathComponent("loss"))
        let home = app.buttons["connection-loss.home"]
        XCTAssertTrue(home.appears(timeout: Self.timeout))
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
