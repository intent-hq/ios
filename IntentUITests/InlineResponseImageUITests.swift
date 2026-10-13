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
            if UIDevice.current.userInterfaceIdiom == .phone {
                app.buttons["conversation.back"].tap()
            } else {
                app.navigationBars.buttons.element(boundBy: 0).tap()
            }
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
    func testPDFCardAndLinkOpenViewerAndShare() {
        let app = XCUIApplication()
        app.launchArguments += ["--demo-data", "--demo-inline-pdfs"]
        app.launch()
        openWorkspace(in: app)
        let agent = app.staticTexts[Fixture.agentName].firstMatch
        XCTAssertTrue(agent.waitForExistence(timeout: Fixture.timeout))
        agent.tap()
        let transcript = app.scrollViews["transcript.scrollView"].firstMatch
        XCTAssertTrue(transcript.waitForExistence(timeout: Fixture.timeout))
        let card = message(in: app, containing: "PDF preview:")
        XCTAssertTrue(card.waitForExistence(timeout: Fixture.timeout))
        reveal(card, in: transcript)
        XCTAssertTrue(waitUntil(timeout: Fixture.timeout) {
            card.frame.height >= Fixture.thumbnailSide
        }, "The inline PDF card must occupy its preview area; opening it below proves it loaded")
        XCTAssertGreaterThanOrEqual(card.frame.minX, transcript.frame.minX)
        XCTAssertLessThanOrEqual(card.frame.maxX, transcript.frame.maxX)
        captureMedia(app, named: "Inline PDF card and link")

        // Textual draws the attachment into the final square of this paragraph.
        card.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: Fixture.thumbnailSide / 2, dy: card.frame.height - Fixture.thumbnailSide / 2))
            .tap()
        assertPDFViewer(in: app)
        captureMedia(app, named: "PDF viewer from inline card")
        let close = app.buttons["pdf.close"].firstMatch
        close.tap()
        XCTAssertTrue(close.waitForNonExistence(timeout: Fixture.timeout))

        assertUnavailablePDFCanClose(in: app, transcript: transcript)

        let link = app.links["Open the PDF brief"].firstMatch
        XCTAssertTrue(link.waitForExistence(timeout: Fixture.timeout))
        reveal(link, in: transcript)
        // Selectable Markdown overlays the semantic link in accessibility hit-testing.
        link.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        assertPDFViewer(in: app)
        captureMedia(app, named: "PDF viewer from text link")
        app.buttons["Share PDF"].firstMatch.tap()
        XCTAssertTrue(
            app.otherElements["ActivityListView"].firstMatch.waitForExistence(timeout: Fixture.timeout),
            "Share must present the native activity sheet"
        )
        captureMedia(app, named: "PDF share sheet")
    }

    @MainActor
    private func assertPDFViewer(in app: XCUIApplication) {
        let viewer = app.descendants(matching: .any).matching(
            NSPredicate(format: "label == %@", "PDF viewer: Demo brief.pdf, 2 pages")
        ).firstMatch
        XCTAssertTrue(viewer.waitForExistence(timeout: Fixture.timeout), "Both PDF entry points must open the document viewer")
        XCTAssertTrue(app.staticTexts["Intent project brief"].firstMatch.waitForExistence(timeout: Fixture.timeout))
        let close = app.buttons["pdf.close"].firstMatch
        let share = app.buttons["Share PDF"].firstMatch
        XCTAssertTrue(waitUntil(timeout: Fixture.timeout) { close.isHittable && share.isHittable })
        XCTAssertEqual(close.label, "Close PDF")
    }

    @MainActor
    private func assertUnavailablePDFCanClose(in app: XCUIApplication, transcript: XCUIElement) {
        let link = app.links["Open the missing PDF"].firstMatch
        XCTAssertTrue(link.waitForExistence(timeout: Fixture.timeout))
        reveal(link, in: transcript)
        link.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        let unavailable = app.staticTexts["PDF unavailable"].firstMatch
        XCTAssertTrue(unavailable.waitForExistence(timeout: Fixture.timeout))
        let close = app.buttons["pdf.close"].firstMatch
        let retry = app.buttons["Retry loading PDF"].firstMatch
        XCTAssertTrue(waitUntil(timeout: Fixture.timeout) { close.isHittable && retry.isHittable })
        XCTAssertEqual(close.label, "Close PDF")
        captureMedia(app, named: "PDF unavailable with close and retry")
        retry.tap()
        XCTAssertTrue(unavailable.waitForExistence(timeout: Fixture.timeout))
        close.tap()
        XCTAssertTrue(unavailable.waitForNonExistence(timeout: Fixture.timeout))
        XCTAssertTrue(close.waitForNonExistence(timeout: Fixture.timeout))
    }

    @MainActor
    private func captureMedia(_ app: XCUIApplication, named name: String) {
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = name
        screenshot.lifetime = .keepAlways
        add(screenshot)
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
            XCTAssertTrue(paragraph.exists || paragraph.waitForExistence(timeout: Fixture.timeout))
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
            let transcriptFrame = transcript.frame
            let paragraphFrame = paragraph.frame
            if transcriptFrame.minY <= paragraphFrame.minY,
               paragraphFrame.maxY <= transcriptFrame.maxY { return }
            if paragraphFrame.minY < transcriptFrame.minY {
                transcript.swipeDown()
            } else {
                transcript.swipeUp()
            }
        }
        XCTAssertTrue(waitUntilVisible(paragraph, in: transcript, timeout: Fixture.timeout))
    }
}

extension InlineResponseImageUITests {
    @MainActor
    func testTextLinkOpensViewerSharesAndRetriesMissingFile() {
        let app = XCUIApplication()
        app.launchArguments += ["--demo-data", "--demo-inline-text"]
        app.launch()
        openWorkspace(in: app)
        let agent = app.staticTexts[Fixture.agentName].firstMatch
        XCTAssertTrue(agent.waitForExistence(timeout: Fixture.timeout))
        agent.tap()
        let transcript = app.scrollViews["transcript.scrollView"].firstMatch
        XCTAssertTrue(transcript.waitForExistence(timeout: Fixture.timeout))
        let link = app.links["Open the text notes"].firstMatch
        XCTAssertTrue(link.waitForExistence(timeout: Fixture.timeout))
        reveal(link, in: transcript)
        link.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()

        assertTextViewerAndShare(in: app)
        let close = app.buttons["text.close"].firstMatch
        close.tap()
        XCTAssertTrue(close.waitForNonExistence(timeout: Fixture.timeout))
        XCTAssertTrue(app.textViews["text.content"].firstMatch.waitForNonExistence(timeout: Fixture.timeout))

        assertUnavailableTextCanClose(in: app, transcript: transcript)
        XCTAssertTrue(link.waitForExistence(timeout: Fixture.timeout))
        let after = message(in: app, containing: "The notes are ready to review and share.")
        XCTAssertTrue(after.waitForExistence(timeout: Fixture.timeout))
        reveal(after, in: transcript)
        XCTAssertTrue(after.isHittable, "Closing either viewer must preserve the surrounding conversation")
    }

    @MainActor
    private func assertTextViewerAndShare(in app: XCUIApplication) {
        let content = app.textViews["text.content"].firstMatch
        XCTAssertTrue(content.waitForExistence(timeout: Fixture.timeout))
        let text = content.value as? String ?? ""
        XCTAssertTrue(text.contains("Intent project notes"))
        XCTAssertTrue(text.contains("Café review — ready to share."))
        XCTAssertTrue(text.contains("3. Return to the conversation."))
        XCTAssertTrue(app.navigationBars["Demo notes.txt"].exists)
        let close = app.buttons["text.close"].firstMatch
        let share = app.buttons["Share text file"].firstMatch
        XCTAssertTrue(waitUntil(timeout: Fixture.timeout) { close.isHittable && share.isHittable })
        XCTAssertEqual(close.label, "Close text file")
        captureMedia(app, named: "Text viewer from text link")
        share.tap()
        let activity = app.otherElements["ActivityListView"].firstMatch
        XCTAssertTrue(activity.waitForExistence(timeout: Fixture.timeout), "Share must present the native activity sheet")
        let dismissRegion = app.otherElements["PopoverDismissRegion"].firstMatch
        if dismissRegion.exists {
            dismissRegion.tap()
        } else {
            activity.swipeDown()
        }
        XCTAssertTrue(activity.waitForNonExistence(timeout: Fixture.timeout))
        XCTAssertTrue(waitUntil(timeout: Fixture.timeout) { close.isHittable })
    }

    @MainActor
    private func assertUnavailableTextCanClose(in app: XCUIApplication, transcript: XCUIElement) {
        let link = app.links["Open the missing text file"].firstMatch
        XCTAssertTrue(link.waitForExistence(timeout: Fixture.timeout))
        reveal(link, in: transcript)
        link.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        let unavailable = app.staticTexts["Text file unavailable"].firstMatch
        XCTAssertTrue(unavailable.waitForExistence(timeout: Fixture.timeout))
        XCTAssertTrue(app.navigationBars["Missing notes.txt"].exists)
        let close = app.buttons["text.close"].firstMatch
        let retry = app.buttons["Retry loading text file"].firstMatch
        XCTAssertTrue(waitUntil(timeout: Fixture.timeout) { close.isHittable && retry.isHittable })
        XCTAssertEqual(close.label, "Close text file")
        XCTAssertFalse(app.buttons["Share text file"].exists)
        captureMedia(app, named: "Text unavailable with close and retry")
        retry.tap()
        XCTAssertTrue(unavailable.waitForExistence(timeout: Fixture.timeout))
        XCTAssertTrue(waitUntil(timeout: Fixture.timeout) { retry.isHittable && close.isHittable })
        close.tap()
        XCTAssertTrue(unavailable.waitForNonExistence(timeout: Fixture.timeout))
        XCTAssertTrue(close.waitForNonExistence(timeout: Fixture.timeout))
    }
}
