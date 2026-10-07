import XCTest

extension ConversationTranscriptScrollUITests {
    @MainActor
    func testLoadingStatusShowsIdleDelayAndRestoresComposer() throws {
        for appearance in ["light", "dark"] {
            try assertLoadingStatus(appearance: appearance)
        }
    }

    @MainActor
    private func assertLoadingStatus(appearance: String) throws {
        let app = try launchStartupConversation(metadataReady: true, holdSnapshot: true, appearance: appearance)
        defer { finishStartup(app) }
        let opened = enterLongConversation(in: app, context: "inline loading status", waitForTranscript: false)
        let block = app.otherElements["conversation.connectionStatusBlock"].firstMatch
        let status = block.buttons["conversation.connectionStatus"]
        let retry = block.buttons["conversation.retryNow"]
        let composer = app.textViews[Fixture.composerIdentifier].firstMatch
        XCTAssertTrue(status.waitForExistence(timeout: Fixture.settleTimeout))
        XCTAssertEqual(status.label, "Asking the daemon", "Only the current message is announced before the idle threshold")
        XCTAssertEqual(status.value as? String, "Collapsed")
        XCTAssertFalse(block.otherElements["Connecting to the daemon, Done"].exists)
        XCTAssertFalse(retry.exists)
        attachLoading(app.screenshot(), named: "Conversation loading before idle \(appearance)")
        XCTAssertFalse(opened.transcript.exists, "The snapshot must remain held while checking loading status")
        XCTAssertFalse(composer.exists, "Loading must hide the message bar")

        status.tap()
        assertExpandedSteps(in: block, status: status)
        status.tap()
        XCTAssertEqual(status.value as? String, "Collapsed")

        XCTAssertTrue(retry.waitForExistence(timeout: Fixture.settleTimeout))
        XCTAssertTrue(status.label.hasPrefix("Asking the daemon, elapsed: "))
        XCTAssertTrue(status.label.contains("Taking longer than usual"))
        XCTAssertTrue(retry.isHittable)
        XCTAssertTrue(block.frame.contains(status.frame))
        XCTAssertTrue(block.frame.contains(retry.frame), "Retry must stay within the same loading group")
        attachLoading(app.screenshot(), named: "Conversation loading after idle \(appearance)")

        // The trailing chevron and the message row share the same disclosure target.
        status.coordinate(withNormalizedOffset: CGVector(dx: 0.97, dy: 0.5)).tap()
        assertExpandedSteps(in: block, status: status)
        XCTAssertTrue(retry.isHittable)
        attachLoading(app.screenshot(), named: "Conversation loading expanded after idle \(appearance)")
        status.tap()
        XCTAssertEqual(status.value as? String, "Collapsed")
        XCTAssertFalse(block.otherElements["Connecting to the daemon, Done"].exists)
        XCTAssertTrue(retry.isHittable, "Collapsing steps must not hide Retry Now")

        try Data().write(to: startupSnapshotGate)
        XCTAssertTrue(opened.transcript.waitForExistence(timeout: Fixture.settleTimeout))
        XCTAssertTrue(waitUntil(timeout: Fixture.settleTimeout) { self.startupReport(app).contains("positioned=true") })
        XCTAssertTrue(composer.waitForExistence(timeout: Fixture.settleTimeout))
        XCTAssertFalse(block.exists)
        XCTAssertFalse(app.buttons["conversation.retryNow"].exists)
    }

    @MainActor
    private func assertExpandedSteps(in block: XCUIElement, status: XCUIElement) {
        XCTAssertEqual(status.value as? String, "Expanded")
        for label in ["Connecting to the daemon, Done", "Asking the daemon, Current", "Receiving messages, Pending"] {
            let step = block.otherElements[label]
            XCTAssertTrue(step.exists, "Expanded loading steps must announce their progress state")
            XCTAssertTrue(block.frame.contains(step.frame))
            XCTAssertGreaterThanOrEqual(step.frame.minY, status.frame.maxY)
        }
    }

    private func attachLoading(_ screenshot: XCUIScreenshot, named name: String) {
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
