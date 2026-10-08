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
        let status = block.otherElements["conversation.connectionStatus"]
        let skeleton = block.otherElements["conversation.loadingSkeleton"]
        let retry = block.buttons["conversation.retryNow"]
        let composer = app.textViews[Fixture.composerIdentifier].firstMatch
        XCTAssertTrue(skeleton.waitForExistence(timeout: Fixture.settleTimeout))
        XCTAssertFalse(retry.exists)
        attachLoading(app.screenshot(), named: "Conversation loading before idle \(appearance)")
        XCTAssertFalse(opened.transcript.exists, "The snapshot must remain held while checking loading status")
        XCTAssertFalse(composer.exists, "Loading must hide the message bar")

        XCTAssertTrue(retry.waitForExistence(timeout: Fixture.settleTimeout))
        XCTAssertFalse(skeleton.exists)
        XCTAssertTrue(status.label.hasPrefix("Requesting messages, Current, elapsed: "))
        XCTAssertTrue(status.label.contains("Taking longer than usual"))
        XCTAssertTrue(retry.isHittable)
        XCTAssertTrue(block.frame.contains(status.frame))
        XCTAssertTrue(block.frame.contains(retry.frame), "Retry must stay within the same loading group")
        assertConnectionSteps(in: block)
        attachLoading(app.screenshot(), named: "Conversation loading after idle \(appearance)")

        try Data().write(to: startupSnapshotGate)
        XCTAssertTrue(opened.transcript.waitForExistence(timeout: Fixture.settleTimeout))
        XCTAssertTrue(waitUntil(timeout: Fixture.settleTimeout) { self.startupReport(app).contains("positioned=true") })
        XCTAssertTrue(composer.waitForExistence(timeout: Fixture.settleTimeout))
        XCTAssertFalse(block.exists)
        XCTAssertFalse(app.buttons["conversation.retryNow"].exists)
    }

    @MainActor
    private func assertConnectionSteps(in block: XCUIElement) {
        var previousBottom = block.frame.minY
        let steps = [("Connecting", "Done"), ("Requesting messages", "Current"), ("Receiving messages", "Pending")]
        for (title, state) in steps {
            let matches = block.otherElements.matching(NSPredicate(format: "label == %@ OR label BEGINSWITH %@", title, "\(title),"))
            XCTAssertEqual(matches.count, 1, "Each step must appear once, without a duplicate header")
            let step = matches.firstMatch
            XCTAssertTrue(step.exists, "Loading steps must always be visible and announce their progress state")
            XCTAssertTrue(step.label.hasPrefix("\(title), \(state)"))
            XCTAssertTrue(block.frame.contains(step.frame))
            XCTAssertGreaterThanOrEqual(step.frame.minY, previousBottom)
            previousBottom = step.frame.maxY
        }
    }

    private func attachLoading(_ screenshot: XCUIScreenshot, named name: String) {
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
