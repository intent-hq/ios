import XCTest

/// Exercises the real assistant message -> Markdown -> saved asset -> lightbox
/// path using only demo RPC responses, including a missing asset and re-entry.
nonisolated final class InlineResponseImageUITests: XCTestCase {
    private enum Fixture {
        static let workspaceTitle = "Add usage analytics dashboard"
        static let agentName = "Dashboard Implementor"
        static let before = "Before the saved image."
        static let between = "After the saved image, before the missing image."
        static let after = "After the missing image. The response is still readable."
        static let savedCaption = "Saved preview:"
        static let missingCaption = "Missing preview:"
        static let prompts = ["Show the recording screen.", "Show the mobile layout."]
        static let timeout: TimeInterval = 15
        static let launchTimeout: TimeInterval = 30
        static let inertTapTimeout: TimeInterval = 2
        static let thumbnailSide: CGFloat = 160
        static let entryCount = 2
        static let maximumScrolls = 3
        static let failureTapVerticalFraction: CGFloat = 0.75
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
    func testSavedAndMissingImagesPreserveResponseAndLightboxAfterReopening() {
        let app = XCUIApplication()
        app.launchArguments += ["--demo-data", "--demo-inline-images"]
        app.launch()
        openWorkspace(in: app)

        for entry in 1...Fixture.entryCount {
            let agent = app.staticTexts[Fixture.agentName].firstMatch
            XCTAssertTrue(agent.waitForExistence(timeout: Fixture.timeout))
            agent.tap()
            let transcript = app.scrollViews["transcript.scrollView"].firstMatch
            XCTAssertTrue(transcript.waitForExistence(timeout: Fixture.timeout))

            assertResponse(in: app, transcript: transcript)
            assertLightbox(in: app, transcript: transcript)
            assertMissingImageIsInert(in: app, transcript: transcript)
            assertResponse(in: app, transcript: transcript)
            assertPrompts(in: app, transcript: transcript)

            let screenshot = XCTAttachment(screenshot: app.screenshot())
            screenshot.name = "Inline image response, entry \(entry)"
            screenshot.lifetime = .keepAlways
            add(screenshot)

            // Return to the overview without restarting the app: the second
            // entry must reconstruct the conversation with cached asset results.
            app.navigationBars.buttons.element(boundBy: 0).tap()
            XCTAssertTrue(app.buttons["Context"].waitForExistence(timeout: Fixture.timeout))
            XCTAssertTrue(transcript.waitForNonExistence(timeout: Fixture.timeout))
        }
    }

    @MainActor
    func testBothImageResponsePromptsSendTheirDisplayedText() {
        for (index, expected) in Fixture.prompts.enumerated() {
            let app = XCUIApplication()
            app.launchArguments += ["--demo-data", "--demo-inline-images"]
            app.launch()
            openWorkspace(in: app)
            let agent = app.staticTexts[Fixture.agentName].firstMatch
            XCTAssertTrue(agent.waitForExistence(timeout: Fixture.timeout))
            agent.tap()
            let transcript = app.scrollViews["transcript.scrollView"].firstMatch
            XCTAssertTrue(transcript.waitForExistence(timeout: Fixture.timeout))
            assertPrompts(in: app, transcript: transcript)
            let prompt = app.buttons["transcript.suggestedPrompt.\(index)"].firstMatch
            reveal(prompt, in: transcript)
            prompt.tap()
            XCTAssertTrue(prompt.waitForNonExistence(timeout: Fixture.timeout))
            let sent = message(in: app, containing: expected)
            XCTAssertTrue(sent.waitForExistence(timeout: Fixture.timeout))
            XCTAssertEqual(sent.label, expected)
            app.terminate()
        }
    }

    @MainActor
    private func assertPrompts(in app: XCUIApplication, transcript: XCUIElement) {
        for (index, expected) in Fixture.prompts.enumerated() {
            let prompt = app.buttons["transcript.suggestedPrompt.\(index)"].firstMatch
            XCTAssertTrue(prompt.waitForExistence(timeout: Fixture.timeout))
            reveal(prompt, in: transcript)
            XCTAssertEqual(prompt.label, expected)
        }
        let rawMarker = transcript.staticTexts.matching(NSPredicate(
            format: "label CONTAINS %@ OR label CONTAINS %@ OR label CONTAINS %@",
            "suggested-prompts",
            "<!--",
            "-->"
        ))
        XCTAssertEqual(rawMarker.count, 0, "Prompt control markup must not appear beside the buttons")
    }

    @MainActor
    private func openWorkspace(in app: XCUIApplication) {
        let workspace = app.staticTexts[Fixture.workspaceTitle].firstMatch
        if !workspace.waitForExistence(timeout: Fixture.launchTimeout) {
            app.navigationBars.buttons.element(boundBy: 0).tap()
            XCTAssertTrue(workspace.waitForExistence(timeout: Fixture.timeout))
        }
        workspace.tap()
        XCTAssertTrue(app.buttons["Context"].waitForExistence(timeout: Fixture.timeout))
    }

    @MainActor
    private func assertResponse(in app: XCUIApplication, transcript: XCUIElement) {
        let before = message(in: app, containing: Fixture.before)
        let saved = message(in: app, containing: Fixture.savedCaption)
        let between = message(in: app, containing: Fixture.between)
        let missing = message(in: app, containing: Fixture.missingCaption)
        let after = message(in: app, containing: Fixture.after)
        for paragraph in [before, saved, between, missing, after] {
            XCTAssertTrue(paragraph.waitForExistence(timeout: Fixture.timeout))
            reveal(paragraph, in: transcript)
        }

        XCTAssertTrue(waitUntil(timeout: Fixture.timeout) {
            saved.frame.height >= Fixture.thumbnailSide
                && missing.frame.height < Fixture.thumbnailSide
                && before.frame.maxY <= saved.frame.minY
                && saved.frame.maxY <= between.frame.minY
                && between.frame.maxY <= missing.frame.minY
                && missing.frame.maxY <= after.frame.minY
        }, "The loaded thumbnail, compact failure placeholder, and surrounding paragraphs must remain in order")
    }

    @MainActor
    private func assertLightbox(in app: XCUIApplication, transcript: XCUIElement) {
        let saved = message(in: app, containing: Fixture.savedCaption)
        reveal(saved, in: transcript)
        // Textual draws attachments in a Canvas. The caption and hard break
        // identify the paragraph; the final 160pt square is the real thumbnail.
        saved.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(
                dx: Fixture.thumbnailSide / 2,
                dy: saved.frame.height - Fixture.thumbnailSide / 2
            ))
            .tap()
        let preview = app.images["Image preview"].firstMatch
        XCTAssertTrue(preview.waitForExistence(timeout: Fixture.timeout), "The saved image did not open the lightbox")
        XCTAssertGreaterThan(preview.frame.width, Fixture.thumbnailSide)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Saved response image in lightbox"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        app.buttons["Close image"].firstMatch.tap()
        XCTAssertTrue(preview.waitForNonExistence(timeout: Fixture.timeout))
    }

    @MainActor
    private func assertMissingImageIsInert(in app: XCUIApplication, transcript: XCUIElement) {
        let missing = message(in: app, containing: Fixture.missingCaption)
        reveal(missing, in: transcript)
        // Hit the second line, occupied by the compact failure attachment.
        missing.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(
                dx: missing.frame.height / 2,
                dy: missing.frame.height * Fixture.failureTapVerticalFraction
            ))
            .tap()
        let opened = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == true"),
            object: app.images["Image preview"].firstMatch
        )
        opened.isInverted = true
        XCTAssertEqual(XCTWaiter.wait(for: [opened], timeout: Fixture.inertTapTimeout), .completed)
    }

    @MainActor
    private func reveal(_ paragraph: XCUIElement, in transcript: XCUIElement) {
        for _ in 0..<Fixture.maximumScrolls {
            if transcript.frame.minY <= paragraph.frame.minY,
               paragraph.frame.maxY <= transcript.frame.maxY { return }
            if paragraph.frame.minY < transcript.frame.minY {
                transcript.swipeDown()
            } else {
                transcript.swipeUp()
            }
        }
        XCTAssertTrue(waitUntilVisible(paragraph, in: transcript, timeout: Fixture.timeout))
    }
}
