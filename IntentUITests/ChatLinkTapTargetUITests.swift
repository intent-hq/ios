import XCTest

/// Chat lines that are only a link render as full-width rows at least 44 pt
/// tall. Taps at a row's top and bottom edges and on its trailing side, away
/// from the link text, must open the link; the message must keep its text
/// selection and long-press Copy menu.
nonisolated final class ChatLinkTapTargetUITests: XCTestCase {
    private enum Outcome {
        case text
        case html
        case message
    }

    private enum Fixture {
        static let workspaceTitle = "Add usage analytics dashboard"
        static let agentName = "Dashboard Implementor"
        static let rowIdentifier = "markdown.linkRow"
        static let links: [(label: String, outcome: Outcome)] = [
            ("Open the text notes", .text),
            ("Open the missing text file", .text),
            ("Open the HTML report", .html),
            ("Open the HTML report by absolute path", .html),
            ("Open the workspace settings", .message),
            ("Open the signed-in preview", .message)
        ]
        static let firstParagraph = "Here are the project notes."
        static let alertTitle = "Can't Open Link"
        static let minimumRowHeight: CGFloat = 44
        /// Accessibility frames carry layout rounding (43.99999999999994).
        static let frameTolerance: CGFloat = 0.01
        /// Rows span the message column, not just the link text.
        static let minimumRowWidthFraction: CGFloat = 0.8
        /// Taps land this far inside the row's top and bottom edges, above and
        /// below the link text line.
        static let edgeInset: CGFloat = 3
        /// Horizontal position of the edge taps: over the start of the title.
        static let edgeTapX: CGFloat = 0.1
        /// The trailing tap is past the end of every title.
        static let trailingTapX: CGFloat = 0.96
        static let timeout: TimeInterval = 15
        static let launchTimeout: TimeInterval = 30
        static let longPressDuration: TimeInterval = 1
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
    func testStandaloneLinkRowsOpenFromEdgesAndTrailingSide() {
        let app = launch(appearance: "light")
        let transcript = openTranscript(in: app)
        let rows = app.links.matching(identifier: Fixture.rowIdentifier)
        XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: Fixture.timeout))
        XCTAssertEqual(rows.count, Fixture.links.count, "Every standalone link line must render as a row")

        for link in Fixture.links {
            let row = rows[link.label].firstMatch
            XCTAssertTrue(row.waitForExistence(timeout: Fixture.timeout), "\(link.label) must be a link row")
            reveal(row, in: transcript)
            let frame = row.frame
            XCTAssertGreaterThanOrEqual(
                frame.height,
                Fixture.minimumRowHeight - Fixture.frameTolerance,
                "\(link.label) row: \(frame)"
            )
            XCTAssertGreaterThanOrEqual(
                frame.width,
                transcript.frame.width * Fixture.minimumRowWidthFraction,
                "\(link.label) row must span the message: \(frame)"
            )
            let origin = row.coordinate(withNormalizedOffset: .zero)
            let taps: [(name: String, point: XCUICoordinate)] = [
                ("top edge", origin.withOffset(CGVector(dx: frame.width * Fixture.edgeTapX, dy: Fixture.edgeInset))),
                (
                    "bottom edge",
                    origin.withOffset(CGVector(dx: frame.width * Fixture.edgeTapX, dy: frame.height - Fixture.edgeInset))
                ),
                ("trailing side", row.coordinate(withNormalizedOffset: CGVector(dx: Fixture.trailingTapX, dy: 0.5)))
            ]
            for tap in taps {
                reveal(row, in: transcript)
                tap.point.tap()
                assertOpensAndClose(link.outcome, in: app, context: "\(link.label), \(tap.name)")
                XCTAssertTrue(transcript.waitForExistence(timeout: Fixture.timeout))
            }
        }
    }

    @MainActor
    func testMessageWithLinksKeepsSelectionAndCopyMenu() {
        let app = launch(appearance: "light")
        let transcript = openTranscript(in: app)
        let paragraph = app.staticTexts.containing(
            NSPredicate(format: "label CONTAINS %@", Fixture.firstParagraph)
        ).firstMatch
        XCTAssertTrue(paragraph.waitForExistence(timeout: Fixture.timeout))
        reveal(paragraph, in: transcript)

        paragraph.press(forDuration: Fixture.longPressDuration)
        let copy = app.menuItems["Copy"].firstMatch
        XCTAssertTrue(copy.waitForExistence(timeout: Fixture.timeout), "The message must keep its Copy menu")
        copy.tap()
        XCTAssertTrue(copy.waitForNonExistence(timeout: Fixture.timeout))

        paragraph.doubleTap()
        let share = app.menuItems["Share…"].firstMatch
        XCTAssertTrue(
            share.waitForExistence(timeout: Fixture.timeout),
            "Double-tapping message text must still select a word and show the edit menu"
        )
        XCTAssertTrue(app.menuItems["Copy"].firstMatch.exists)
    }

    @MainActor
    func testLinkRowsInLightAndDark() {
        for appearance in ["light", "dark"] {
            let app = launch(appearance: appearance)
            let transcript = openTranscript(in: app)
            let first = app.links[Fixture.links[0].label].firstMatch
            XCTAssertTrue(first.waitForExistence(timeout: Fixture.timeout))
            reveal(first, in: transcript)
            let screenshot = XCTAttachment(screenshot: app.screenshot())
            screenshot.name = "Chat link rows \(appearance)"
            screenshot.lifetime = .keepAlways
            add(screenshot)
            app.terminate()
        }
    }

    @MainActor
    private func launch(appearance: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["--demo-data", "--demo-inline-text", "-appThemePreference", appearance]
        app.launch()
        return app
    }

    @MainActor
    private func assertOpensAndClose(_ outcome: Outcome, in app: XCUIApplication, context: String) {
        switch outcome {
        case .text:
            close(app.buttons["text.close"].firstMatch, context: context)
        case .html:
            close(app.buttons["html.close"].firstMatch, context: context)
        case .message:
            let alert = app.alerts[Fixture.alertTitle].firstMatch
            XCTAssertTrue(alert.waitForExistence(timeout: Fixture.timeout), "\(context) must open the link")
            alert.buttons["OK"].tap()
            XCTAssertTrue(alert.waitForNonExistence(timeout: Fixture.timeout))
        }
    }

    @MainActor
    private func close(_ button: XCUIElement, context: String) {
        XCTAssertTrue(button.waitForExistence(timeout: Fixture.timeout), "\(context) must open the link")
        XCTAssertTrue(waitUntil(timeout: Fixture.timeout) { button.isHittable })
        button.tap()
        XCTAssertTrue(button.waitForNonExistence(timeout: Fixture.timeout))
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
