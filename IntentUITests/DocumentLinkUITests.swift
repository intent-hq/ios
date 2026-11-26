import XCTest

nonisolated final class DocumentLinkUITests: XCTestCase {
    private enum Fixture {
        static let workspaceTitle = "Add usage analytics dashboard"
        static let agentName = "Dashboard Implementor"
        static let linkLabel = "Open the budget spreadsheet"
        static let missingLinkLabel = "Open the missing spreadsheet"
        static let fileName = "Demo budget.xlsx"
        static let missingFileName = "Missing budget.xlsx"
        static let cellText = "Quarter"
        static let timeout: TimeInterval = 15
        static let launchTimeout: TimeInterval = 30
    }

    override func setUpWithError() throws {
        try super.setUpWithError()
        continueAfterFailure = false
    }

    override func tearDownWithError() throws {
        continueAfterFailure = true
        try super.tearDownWithError()
    }

    @MainActor
    func testSpreadsheetLinkOpensDocumentViewer() {
        for appearance in ["light", "dark"] {
            let app = launch(appearance: appearance)
            let transcript = openTranscript(in: app)
            tapLink(Fixture.linkLabel, in: app)

            XCTAssertTrue(app.navigationBars[Fixture.fileName].waitForExistence(timeout: Fixture.timeout))
            let cell = app.descendants(matching: .any).matching(
                NSPredicate(format: "label == %@ OR value == %@", Fixture.cellText, Fixture.cellText)
            ).firstMatch
            XCTAssertTrue(cell.waitForExistence(timeout: Fixture.timeout), "The spreadsheet cells must render, not a text-file error")
            XCTAssertFalse(app.staticTexts["Text file unavailable"].exists)
            let close = app.buttons["document.close"].firstMatch
            let share = app.buttons["document.share"].firstMatch
            XCTAssertTrue(waitUntil(timeout: Fixture.timeout) { close.isHittable && share.isHittable })
            let loading = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Loading")).firstMatch
            XCTAssertTrue(waitUntil(timeout: Fixture.timeout) { !loading.exists })
            captureMedia(app, named: "Spreadsheet viewer from text link \(appearance)")

            close.tap()
            XCTAssertTrue(close.waitForNonExistence(timeout: Fixture.timeout))
            XCTAssertTrue(transcript.exists, "Closing the viewer must keep the conversation open")
            app.terminate()
        }
    }

    @MainActor
    func testSpreadsheetShareKeepsOriginalName() {
        let app = launch(appearance: "light")
        _ = openTranscript(in: app)
        tapLink(Fixture.linkLabel, in: app)

        let share = app.buttons["document.share"].firstMatch
        XCTAssertTrue(share.waitForExistence(timeout: Fixture.timeout))
        XCTAssertTrue(waitUntil(timeout: Fixture.timeout) { share.isHittable })
        share.tap()
        let activity = app.otherElements["ActivityListView"].firstMatch
        XCTAssertTrue(activity.waitForExistence(timeout: Fixture.timeout), "Share must present the native activity sheet")
        let named = activity.descendants(matching: .any).matching(
            NSPredicate(format: "label CONTAINS %@", "Demo budget")
        ).firstMatch
        XCTAssertTrue(named.waitForExistence(timeout: Fixture.timeout), "Share sheet must show the original file name")
        captureMedia(app, named: "Spreadsheet share sheet")
    }

    @MainActor
    func testMissingSpreadsheetShowsUnavailableWithRetryAndClose() {
        let app = launch(appearance: "light")
        let transcript = openTranscript(in: app)
        tapLink(Fixture.missingLinkLabel, in: app)

        XCTAssertTrue(app.navigationBars[Fixture.missingFileName].waitForExistence(timeout: Fixture.timeout))
        let unavailable = app.staticTexts["File unavailable"].firstMatch
        XCTAssertTrue(unavailable.waitForExistence(timeout: Fixture.timeout))
        let retry = app.buttons["Retry"].firstMatch
        let close = app.buttons["Close file"].firstMatch
        XCTAssertTrue(waitUntil(timeout: Fixture.timeout) { close.isHittable && retry.isHittable })
        captureMedia(app, named: "Spreadsheet unavailable with close and retry")
        retry.tap()
        XCTAssertTrue(unavailable.waitForExistence(timeout: Fixture.timeout))
        close.tap()
        XCTAssertTrue(unavailable.waitForNonExistence(timeout: Fixture.timeout))
        XCTAssertTrue(transcript.exists, "Closing the failed preview must keep the conversation open")
    }

    @MainActor
    private func launch(appearance: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["--demo-data", "--demo-inline-documents", "-appThemePreference", appearance]
        app.launch()
        return app
    }

    @MainActor
    private func openTranscript(in app: XCUIApplication) -> XCUIElement {
        let workspace = app.staticTexts[Fixture.workspaceTitle].firstMatch
        if !workspace.waitForExistence(timeout: Fixture.launchTimeout) {
            app.navigationBars.buttons.element(boundBy: 0).tap()
            XCTAssertTrue(workspace.waitForExistence(timeout: Fixture.timeout))
        }
        workspace.tap()
        let agent = app.staticTexts[Fixture.agentName].firstMatch
        XCTAssertTrue(agent.waitForExistence(timeout: Fixture.timeout))
        agent.tap()
        let transcript = app.scrollViews["transcript.scrollView"].firstMatch
        XCTAssertTrue(transcript.waitForExistence(timeout: Fixture.timeout))
        return transcript
    }

    @MainActor
    private func tapLink(_ label: String, in app: XCUIApplication) {
        let link = app.links[label].firstMatch
        XCTAssertTrue(link.waitForExistence(timeout: Fixture.timeout))
        XCTAssertTrue(waitUntil(timeout: Fixture.timeout) { link.isHittable })
        link.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
    }

    @MainActor
    private func captureMedia(_ app: XCUIApplication, named name: String) {
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = name
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }
}
