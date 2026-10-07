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
        let status = app.descendants(matching: .any)["conversation.connectionStatus"].firstMatch
        let retry = app.buttons["conversation.retryNow"]
        let composer = app.textViews[Fixture.composerIdentifier].firstMatch
        XCTAssertTrue(status.waitForExistence(timeout: Fixture.settleTimeout))
        XCTAssertEqual(status.label, "Asking the daemon", "Only the current message is announced before the idle threshold")
        XCTAssertFalse(retry.exists)
        attachLoading(app.screenshot(), named: "Conversation loading before idle \(appearance)")
        XCTAssertFalse(opened.transcript.exists, "The snapshot must remain held while checking loading status")
        XCTAssertFalse(composer.exists, "Loading must hide the message bar")

        XCTAssertTrue(retry.waitForExistence(timeout: Fixture.settleTimeout))
        XCTAssertTrue(status.label.hasPrefix("Asking the daemon, elapsed: "))
        XCTAssertTrue(status.label.contains("Taking longer than usual"))
        XCTAssertTrue(retry.isHittable)
        XCTAssertFalse(app.buttons["conversation.connectionDetails"].exists, "Delay details must not be a disclosure")
        attachLoading(app.screenshot(), named: "Conversation loading after idle \(appearance)")

        try Data().write(to: startupSnapshotGate)
        XCTAssertTrue(opened.transcript.waitForExistence(timeout: Fixture.settleTimeout))
        XCTAssertTrue(waitUntil(timeout: Fixture.settleTimeout) { self.startupReport(app).contains("positioned=true") })
        XCTAssertTrue(composer.waitForExistence(timeout: Fixture.settleTimeout))
        XCTAssertFalse(status.exists)
        XCTAssertFalse(retry.exists)
    }

    private func attachLoading(_ screenshot: XCUIScreenshot, named name: String) {
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
