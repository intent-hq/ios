import UIKit
import XCTest

/// Exercises the real composer and monitor actions through the deterministic
/// design demo's transport, not a separate screenshot-only screen.
nonisolated final class WorkspaceComposerUITests: XCTestCase {
    private enum Fixture {
        static let timeout: TimeInterval = 15
        static let minimumTapTarget: CGFloat = 44
        static let workspace = "Workspace agent design"
        static let agent = "Continue Spec Writer"
        static let monitor = "monitoredPr.demo-design-pr-56"
        /// Mirrors Constants.Conversation.Composer.maximumImageSelectionCount.
        static let imageLimit = 10
    }

    @MainActor
    func testTranscriptTapDismissesKeyboardAndPreservesDraft() throws {
        let app = launch(scenario: "composer")
        let composer = app.textViews["composer.textView"]
        let keyboard = app.keyboards.firstMatch
        assertRestingComposerPlacement(in: app, composer: composer)
        composer.tap()
        composer.typeText("Keep this unsent draft")
        XCTAssertTrue(keyboard.waitForExistence(timeout: Fixture.timeout))
        attachComposerGeometry(in: app, composer: composer, state: "keyboard visible")
        let transcript = app.scrollViews["transcript.scrollView"]
        transcript.coordinate(withNormalizedOffset: CGVector(dx: 0.02, dy: 0.5)).tap()

        let dismissed = keyboard.waitForNonExistence(timeout: Fixture.timeout)
        let composerFocused = try XCTUnwrap(composer.value(forKey: "hasKeyboardFocus") as? Bool)
        XCTAssertTrue(dismissed, "A transcript tap must dismiss the keyboard; composer focus: \(composerFocused)")
        XCTAssertFalse(composerFocused)
        XCTAssertEqual(composer.value as? String, "Keep this unsent draft")
        attachComposerGeometry(in: app, composer: composer, state: "keyboard dismissed")
        let reopened = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true"), object: keyboard)
        reopened.isInverted = true
        XCTAssertEqual(XCTWaiter.wait(for: [reopened], timeout: 2), .completed)

        composer.tap()
        XCTAssertTrue(keyboard.waitForExistence(timeout: Fixture.timeout), "An explicit tap must still focus the editor")
        XCTAssertEqual(composer.value as? String, "Keep this unsent draft")
    }

    @MainActor
    func testMultilineSendAndStopPreserveAnInProgressDraft() {
        let app = launch(scenario: "composer")
        let composer = app.textViews["composer.textView"]
        let send = app.buttons["composer.send"]
        let stop = app.buttons["composer.stop"]
        XCTAssertFalse(send.exists, "The empty composer has no send action")
        XCTAssertFalse(stop.exists)

        composer.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: Fixture.timeout))
        let message = "Make the logo bigger\nand keep its proportions"
        enterMultilineMessage(message, into: composer, in: app)
        // Input delivery and the accessibility value can settle after input returns.
        let typedMessage = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == %@", message), object: composer
        )
        XCTAssertEqual(XCTWaiter.wait(for: [typedMessage], timeout: Fixture.timeout), .completed)
        XCTAssertEqual(composer.value as? String, message, "The multiline draft must remain unsent until the send button is tapped")
        XCTAssertTrue(send.waitForExistence(timeout: Fixture.timeout))
        assertReachable(send, in: app)
        send.tap()

        XCTAssertTrue(stop.waitForExistence(timeout: Fixture.timeout), "The actual send starts a streaming response")
        XCTAssertEqual(composer.value as? String, "")
        let sentMessage = app.scrollViews["transcript.scrollView"].staticTexts
            .matching(NSPredicate(format: "label CONTAINS %@ AND label CONTAINS %@", "Make the logo bigger", "keep its proportions"))
            .firstMatch
        XCTAssertTrue(sentMessage.waitForExistence(timeout: Fixture.timeout))
        assertSendDismissesKeyboard(in: app, sentMessage: sentMessage)

        let draft = "Keep this draft while stopping"
        composer.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: Fixture.timeout), "Tapping the composer must reopen the keyboard")
        XCTAssertEqual(composer.value(forKey: "hasKeyboardFocus") as? Bool, true)
        composer.typeText(draft)
        XCTAssertTrue(send.waitForExistence(timeout: Fixture.timeout))
        assertReachable(send, in: app)
        assertReachable(stop, in: app)
        assertReachable(app.buttons["composer.attachment"], in: app)
        stop.tap()
        XCTAssertTrue(stop.waitForNonExistence(timeout: Fixture.timeout))
        XCTAssertEqual(composer.value as? String, draft, "Stop must not consume the next message")
        XCTAssertTrue(send.isEnabled)
    }

    @MainActor
    private func enterMultilineMessage(_ message: String, into composer: XCUIElement, in app: XCUIApplication) {
        if UIDevice.current.userInterfaceIdiom == .pad {
            // iPad Return submits. Native paste inserts a multiline draft without
            // changing that keyboard policy or sending the first line early.
            UIPasteboard.general.string = message
            defer { UIPasteboard.general.items = [] }
            pasteClipboard(into: composer, in: app)
        } else {
            // Keep exercising the iPhone software Return newline behavior.
            composer.typeText(message)
        }
    }

    @MainActor
    private func assertSendDismissesKeyboard(in app: XCUIApplication, sentMessage: XCUIElement) {
        let keyboard = app.keyboards.firstMatch
        XCTAssertTrue(keyboard.waitForNonExistence(timeout: Fixture.timeout), "Sending must dismiss the keyboard")
        let composer = app.textViews["composer.textView"]
        XCTAssertEqual(composer.value(forKey: "hasKeyboardFocus") as? Bool, false, "Sending must leave the composer unfocused")
        let transcript = app.scrollViews["transcript.scrollView"]
        let opened = OpenConversation(lastMessage: sentMessage, goToEnd: app.buttons["transcript.goToEnd"], transcript: transcript)
        assertAtEnd(.thinkingIndicator(in: app), in: opened, context: "after sending and closing the keyboard")
        XCTAssertTrue(isVisible(sentMessage, in: transcript), "The sent message must remain visible without scrolling")
        let reopened = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true"), object: keyboard)
        reopened.isInverted = true
        XCTAssertEqual(XCTWaiter.wait(for: [reopened], timeout: 2), .completed, "The keyboard must stay closed until the composer is tapped")
        XCTAssertEqual(composer.value(forKey: "hasKeyboardFocus") as? Bool, false)
    }

    @MainActor
    func testNativePasteKeepsTextAndImageDraft() {
        let app = launch(scenario: "composer")
        let composer = app.textViews["composer.textView"]
        composer.tap()
        UIPasteboard.general.string = "Keep this draft"
        defer { UIPasteboard.general.items = [] }
        pasteClipboard(into: composer, in: app)
        XCTAssertEqual(composer.value as? String, "Keep this draft")
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 40, height: 30))
        UIPasteboard.general.image = renderer.image { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 40, height: 30))
        }
        pasteClipboard(into: composer, in: app)
        let remove = app.buttons["Remove image 1"]
        XCTAssertTrue(remove.waitForExistence(timeout: Fixture.timeout))
        XCTAssertEqual(composer.value as? String, "Keep this draft")
        XCTAssertTrue(app.buttons["composer.send"].isEnabled)
        remove.tap()
        XCTAssertTrue(remove.waitForNonExistence(timeout: Fixture.timeout))
        XCTAssertEqual(composer.value as? String, "Keep this draft")
    }

    /// #861: pending images keep their slots, but library videos import as
    /// files. At the image limit Photos stays available for videos only.
    @MainActor
    func testPhotosOffersOnlyVideosAtTheImageLimit() {
        let app = launch(scenario: "composer")
        let composer = app.textViews["composer.textView"]
        composer.tap()
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 40, height: 30))
        let colors = (0..<Fixture.imageLimit).map { UIColor(hue: CGFloat($0) / CGFloat(Fixture.imageLimit), saturation: 0.8, brightness: 0.9, alpha: 1) }
        UIPasteboard.general.images = colors.map { color in
            renderer.image { context in
                color.setFill()
                context.fill(CGRect(x: 0, y: 0, width: 40, height: 30))
            }
        }
        defer { UIPasteboard.general.items = [] }
        pasteClipboard(into: composer, in: app)
        XCTAssertTrue(app.buttons["Remove image \(colors.count)"].waitForExistence(timeout: Fixture.timeout))

        let attachment = app.buttons["composer.attachment"]
        assertReachable(attachment, in: app)
        attachment.tap()
        let photos = app.buttons["Photos"]
        XCTAssertTrue(photos.waitForExistence(timeout: Fixture.timeout))
        XCTAssertTrue(photos.isEnabled, "Library videos do not use image slots")
        XCTAssertTrue(app.buttons["Files"].isEnabled)
        let menuShot = XCTAttachment(screenshot: app.screenshot())
        menuShot.name = "Composer attachment menu at image limit"
        menuShot.lifetime = .keepAlways
        add(menuShot)
        photos.tap()
        let cancel = app.buttons["Cancel"].firstMatch
        XCTAssertTrue(cancel.waitForExistence(timeout: Fixture.timeout), "Photos must open at the image limit")
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Composer Photos offers videos at image limit"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        cancel.tap()
        XCTAssertTrue(app.buttons["Remove image \(colors.count)"].waitForExistence(timeout: Fixture.timeout))
    }

    @MainActor
    private func pasteClipboard(into editor: XCUIElement, in app: XCUIApplication) {
        editor.press(forDuration: 1.2)
        let paste = app.menuItems["Paste"]
        XCTAssertTrue(paste.waitForExistence(timeout: Fixture.timeout))
        paste.tap()
        let allowPaste = app.alerts.buttons["Allow Paste"]
        if allowPaste.waitForExistence(timeout: 2) { allowPaste.tap() }
    }

    @MainActor
    func testMonitoringAndAttachmentMenusKeepTheirActions() {
        let app = launch(scenario: "conversation")
        let actions = app.buttons["conversation.actions.open"]
        assertReachable(actions, in: app)
        assertReachable(app.buttons["conversation.back"], in: app)
        actions.tap()
        XCTAssertTrue(app.buttons["Rename"].waitForExistence(timeout: Fixture.timeout))
        XCTAssertTrue(app.buttons["Delete Agent"].exists)
        app.scrollViews["transcript.scrollView"].coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.5)).tap()
        XCTAssertTrue(app.buttons["Rename"].waitForNonExistence(timeout: Fixture.timeout))
        let monitor = app.buttons[Fixture.monitor]
        XCTAssertTrue(monitor.waitForExistence(timeout: Fixture.timeout))
        XCTAssertEqual(app.buttons.matching(identifier: Fixture.monitor).count, 1)
        XCTAssertEqual(monitor.label, "Monitoring PR #56")
        assertTapTargetGeometry(monitor, in: app)
        // iOS 18 reports this native Menu wrapper as non-hittable even though
        // physical touch opens it. Prove routing and actions, not that AX hint.
        monitor.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(app.buttons["Check and flush"].waitForExistence(timeout: Fixture.timeout))
        XCTAssertTrue(app.buttons["Open PR"].exists)
        let cancel = app.buttons["Cancel monitor"]
        XCTAssertTrue(cancel.exists)
        cancel.tap()
        XCTAssertTrue(monitor.waitForNonExistence(timeout: Fixture.timeout), "Cancellation must remove the live monitor")

        let attachment = app.buttons["composer.attachment"]
        assertReachable(attachment, in: app)
        attachment.tap()
        XCTAssertTrue(app.buttons["Photos"].waitForExistence(timeout: Fixture.timeout))
        XCTAssertTrue(app.buttons["Files"].exists)
    }

    @MainActor
    func testAccessibilityTextKeepsDraftAndStreamingActionsReachable() {
        let app = launch(scenario: "streaming", accessibleText: true)
        let composer = app.textViews["composer.textView"]
        composer.tap()
        let draft = "An accessible draft with enough text to wrap onto multiple lines"
        composer.typeText(draft)
        XCTAssertEqual(composer.value as? String, draft)
        let send = app.buttons["composer.send"]
        XCTAssertTrue(send.waitForExistence(timeout: Fixture.timeout))
        assertReachable(send, in: app)
        assertReachable(app.buttons["composer.stop"], in: app)
        assertReachable(app.buttons["composer.attachment"], in: app)
    }

    @MainActor
    private func launch(scenario: String, accessibleText: Bool = false) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments += ["--demo-data", "--demo-design-scenario=\(scenario)"]
        if accessibleText {
            app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        }
        app.launch()
        let workspace = app.staticTexts[Fixture.workspace].firstMatch
        XCTAssertTrue(workspace.waitForExistence(timeout: Fixture.timeout))
        workspace.tap()
        XCTAssertTrue(app.buttons["Context"].waitForExistence(timeout: Fixture.timeout))
        let agent = app.staticTexts[Fixture.agent].firstMatch
        XCTAssertTrue(agent.waitForExistence(timeout: Fixture.timeout))
        agent.tap()
        XCTAssertTrue(app.textViews["composer.textView"].waitForExistence(timeout: Fixture.timeout))
        return app
    }

    @MainActor
    private func assertReachable(_ control: XCUIElement, in app: XCUIApplication) {
        XCTAssertTrue(control.isHittable, control.debugDescription)
        assertTapTargetGeometry(control, in: app)
    }

    @MainActor
    private func assertRestingComposerPlacement(in app: XCUIApplication, composer: XCUIElement) {
        XCTAssertFalse(app.keyboards.firstMatch.exists)
        XCTAssertTrue(composer.isHittable)
        let launcher = app.buttons["intent.menu.open"]
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Workspace composer resting placement"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        attachComposerGeometry(in: app, composer: composer, state: "resting")
        if ProcessInfo.processInfo.environment["INTENT_UITEST_VERTICAL_BAR"] == "1" {
            XCTAssertTrue(launcher.exists)
            XCTAssertEqual(launcher.frame.width, 48, accuracy: 1, "The test must run with the Duo rail")
            XCTAssertGreaterThan(launcher.frame.minX, composer.frame.maxX)
            XCTAssertEqual(composer.frame.midY, launcher.frame.midY, accuracy: 1, "Duo's message field and Intent button must share a vertical center")
        }
    }

    @MainActor
    private func attachComposerGeometry(in app: XCUIApplication, composer: XCUIElement, state: String) {
        let launcher = app.buttons["intent.menu.open"]
        let keyboard = app.keyboards.firstMatch
        let geometry = XCTAttachment(string: "composer=\(composer.frame) launcher=\(launcher.exists ? launcher.frame : .zero) keyboard=\(keyboard.exists ? keyboard.frame : .zero)")
        geometry.name = "Workspace composer \(state) geometry"
        geometry.lifetime = .keepAlways
        add(geometry)
    }

    @MainActor
    private func assertTapTargetGeometry(_ control: XCUIElement, in app: XCUIApplication) {
        // Endpoint addition can differ by one representable value for the same
        // 44pt frame. Admit only that single ULP, not a geometric tolerance.
        let frame = control.frame
        XCTAssertGreaterThanOrEqual(frame.maxX.nextUp, frame.minX + Fixture.minimumTapTarget)
        XCTAssertGreaterThanOrEqual(frame.maxY.nextUp, frame.minY + Fixture.minimumTapTarget)
        XCTAssertTrue(app.frame.contains(control.frame), "Control must not be clipped by the viewport")
    }
}
