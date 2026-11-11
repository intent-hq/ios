import XCTest

/// Taps a transcript link an agent wrote as a relative path (`reports/Demo report.html`)
/// and checks that it opens in the HTML viewer instead of the Can't Open Link message.
nonisolated final class PathFileLinkUITests: XCTestCase {
    private enum Fixture {
        static let workspaceTitle = "Add usage analytics dashboard"
        static let agentName = "Dashboard Implementor"
        static let linkLabel = "Open the HTML report"
        static let fileName = "Demo report.html"
        static let heading = "Usage analytics report"
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
    func testRelativeHTMLPathLinkOpensHTMLViewer() {
        for appearance in ["light", "dark"] {
            let app = XCUIApplication()
            app.launchArguments += ["--demo-data", "--demo-inline-text", "-appThemePreference", appearance]
            app.launch()
            let transcript = openTranscript(in: app)

            let link = app.links[Fixture.linkLabel].firstMatch
            XCTAssertTrue(link.waitForExistence(timeout: Fixture.timeout))
            reveal(link, in: transcript)
            link.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()

            XCTAssertTrue(app.navigationBars[Fixture.fileName].waitForExistence(timeout: Fixture.timeout))
            let page = app.webViews["html.content"].firstMatch
            XCTAssertTrue(page.waitForExistence(timeout: Fixture.timeout))
            XCTAssertTrue(page.staticTexts[Fixture.heading].waitForExistence(timeout: Fixture.timeout))
            XCTAssertFalse(app.alerts[Fixture.alertTitle].exists, "A resolvable path link must not show the message")
            captureMedia(app, named: "HTML viewer from relative path link \(appearance)")

            let close = app.buttons["html.close"].firstMatch
            XCTAssertTrue(waitUntil(timeout: Fixture.timeout) { close.isHittable })
            close.tap()
            XCTAssertTrue(page.waitForNonExistence(timeout: Fixture.timeout))
            XCTAssertTrue(transcript.exists, "Closing the viewer must keep the conversation open")
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
