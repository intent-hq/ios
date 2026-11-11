import XCTest

/// Taps transcript links the app can't open and checks that each tap shows
/// the Can't Open Link message with the link target and a Copy Link action.
nonisolated final class UnopenableLinkUITests: XCTestCase {
    private enum Fixture {
        static let workspaceTitle = "Add usage analytics dashboard"
        static let agentName = "Dashboard Implementor"
        static let alertTitle = "Can't Open Link"
        static let timeout: TimeInterval = 15
        static let launchTimeout: TimeInterval = 30
        static let maximumScrolls = 3
        static let scrollPressDuration: TimeInterval = 0.05
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
    func testUnopenableLinksShowMessageWithCopyLink() {
        for appearance in ["light", "dark"] {
            let app = XCUIApplication()
            app.launchArguments += ["--demo-data", "--demo-inline-text", "-appThemePreference", appearance]
            app.launch()
            let transcript = openTranscript(in: app)

            let intentAlert = tapLink("Open the workspace settings", in: app, transcript: transcript)
            XCTAssertTrue(alertText(intentAlert, contains: "This link can't be opened on this device."))
            XCTAssertTrue(alertText(intentAlert, contains: "intent://local/settings"))
            captureMedia(app, named: "Unopenable link message \(appearance)")
            intentAlert.buttons["Copy Link"].tap()
            XCTAssertTrue(intentAlert.waitForNonExistence(timeout: Fixture.timeout))

            let browserAlert = tapLink("Open the signed-in preview", in: app, transcript: transcript)
            XCTAssertTrue(alertText(browserAlert, contains: "The in-app browser couldn't open this link."))
            XCTAssertTrue(alertText(browserAlert, contains: "http://user@localhost:3000"))
            captureMedia(app, named: "In-app browser failure message \(appearance)")
            browserAlert.buttons["OK"].tap()
            XCTAssertTrue(browserAlert.waitForNonExistence(timeout: Fixture.timeout))
            XCTAssertTrue(transcript.exists, "Dismissing the message must keep the conversation open")
            app.terminate()
        }
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

    /// Taps the named link and returns the message it presents.
    @MainActor
    private func tapLink(_ label: String, in app: XCUIApplication, transcript: XCUIElement) -> XCUIElement {
        let link = app.links[label].firstMatch
        XCTAssertTrue(link.waitForExistence(timeout: Fixture.timeout))
        reveal(link, in: transcript)
        link.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        let alert = app.alerts[Fixture.alertTitle].firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: Fixture.timeout), "Tapping \(label) must show a message")
        XCTAssertTrue(alert.buttons["Copy Link"].exists)
        XCTAssertTrue(alert.buttons["OK"].exists)
        return alert
    }

    @MainActor
    private func alertText(_ alert: XCUIElement, contains text: String) -> Bool {
        alert.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch.exists
    }

    @MainActor
    private func captureMedia(_ app: XCUIApplication, named name: String) {
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = name
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    @MainActor
    private func reveal(_ element: XCUIElement, in transcript: XCUIElement) {
        for _ in 0..<Fixture.maximumScrolls {
            let transcriptFrame = transcript.frame
            let elementFrame = element.frame
            if transcriptFrame.minY <= elementFrame.minY,
               elementFrame.maxY <= transcriptFrame.maxY { return }
            let distance = elementFrame.minY < transcriptFrame.minY
                ? transcriptFrame.minY - elementFrame.minY
                : transcriptFrame.maxY - elementFrame.maxY
            let limit = transcriptFrame.height / 2
            let start = transcript.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            let end = start.withOffset(CGVector(dx: 0, dy: min(limit, max(-limit, distance))))
            start.press(forDuration: Fixture.scrollPressDuration, thenDragTo: end)
        }
        XCTAssertTrue(waitUntilVisible(element, in: transcript, timeout: Fixture.timeout))
    }
}
