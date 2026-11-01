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

        XCTAssertTrue(status.waitForExistence(timeout: Fixture.settleTimeout))
        XCTAssertFalse(skeleton.exists)
        XCTAssertTrue(retry.waitForExistence(timeout: Fixture.settleTimeout))
        XCTAssertTrue(status.label.hasPrefix("Requesting messages, Current, elapsed: "))
        XCTAssertTrue(status.label.contains("Taking longer than usual"))
        XCTAssertTrue(retry.isHittable)
        XCTAssertTrue(block.frame.contains(status.frame))
        XCTAssertTrue(block.frame.insetBy(dx: -1, dy: -1).contains(retry.frame), "Retry must stay within the same loading group")
        assertConnectionSteps(in: block)
        attachLoading(app.screenshot(), named: "Conversation loading after idle \(appearance)")

        try Data().write(to: startupSnapshotGate)
        XCTAssertTrue(opened.transcript.waitForExistence(timeout: Fixture.settleTimeout))
        XCTAssertTrue(waitUntil(timeout: Fixture.settleTimeout) { self.startupReport(app).contains("positioned=true") })
        XCTAssertTrue(composer.waitForExistence(timeout: Fixture.settleTimeout))
        XCTAssertFalse(block.exists)
        XCTAssertFalse(app.buttons["conversation.retryNow"].exists)
    }

    /// Four 5s snapshot timeouts plus 1+2+4s of backoff, with launch headroom.
    private static let loadFailureTimeout: TimeInterval = 60
    private var startupDeliveryGate: URL { hooksRowTriggerFile.appendingPathExtension("delivery") }

    /// #765: snapshots that never arrive end the bounded retry cycle in a
    /// failed state with Retry, which then loads the transcript.
    @MainActor
    func testUndeliveredSnapshotEndsInFailedStateWithRetry() throws {
        for (appearance, largeText) in [("light", false), ("dark", false), ("light", true)] {
            try assertLoadFailure(appearance: appearance, largeText: largeText)
        }
    }

    @MainActor
    private func assertLoadFailure(appearance: String, largeText: Bool) throws {
        try? FileManager.default.removeItem(at: startupDeliveryGate)
        let textSize = largeText ? ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"] : []
        let app = try launchStartupConversation(
            metadataReady: true,
            appearance: appearance,
            extraArguments: ["--demo-chat-delivery-trigger-file=" + startupDeliveryGate.path] + textSize
        )
        defer {
            finishStartup(app)
            try? FileManager.default.removeItem(at: startupDeliveryGate)
        }
        let opened = enterLongConversation(in: app, context: "load failure", waitForTranscript: false)
        let block = app.otherElements["conversation.loadFailedBlock"].firstMatch
        XCTAssertTrue(block.waitForExistence(timeout: Self.loadFailureTimeout), "The bounded cycle must settle on the failed state")
        let suffix = largeText ? "\(appearance) largest text" : appearance
        attachLoading(app.screenshot(), named: "Conversation load failed \(suffix)")
        let message = block.descendants(matching: .any)["conversation.loadFailed"]
        let retry = block.buttons["conversation.retryNow"]
        XCTAssertTrue(message.exists)
        XCTAssertTrue(message.label.hasPrefix("Couldn't load this conversation"))
        XCTAssertTrue(retry.isHittable)
        XCTAssertEqual(retry.label, "Retry")
        XCTAssertTrue(block.frame.insetBy(dx: -1, dy: -1).contains(retry.frame), "Retry \(retry.frame) must sit inside the failed block \(block.frame)")
        XCTAssertFalse(app.otherElements["conversation.connectionStatusBlock"].exists, "No spinner once the load failed")
        XCTAssertFalse(opened.transcript.exists)

        try Data().write(to: startupDeliveryGate)
        retry.tap()
        XCTAssertTrue(opened.transcript.waitForExistence(timeout: Fixture.settleTimeout), "Retry must load the transcript")
        XCTAssertFalse(block.exists)
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
