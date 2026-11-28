import XCTest

private typealias LossFixture = ConnectionLossUITestFixture

extension ConnectionLossUITests {
    @MainActor
    func testBannerKeepsRecentScreensReadableWhileReconnecting() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .phone, "Walks the phone navigation stack")
        let directory = try makeTriggerDirectory()
        let app = launch(directory: directory, arguments: ["--demo-connection-loss-reconnecting"])
        openConversation(in: app)
        XCTAssertTrue(app.scrollViews["transcript.scrollView"].firstMatch.appears(timeout: LossFixture.timeout))
        tap(app.buttons["conversation.back"], in: app)
        openSpecNote(in: app)
        returnToWorkspaceList(in: app)
        app.openHomeAction("assistant")
        XCTAssertTrue(app.buttons["assistant.actions"].appears(timeout: LossFixture.timeout))
        closeAssistant(in: app)

        try trigger("loss", in: directory)
        assertBanner(in: app)
        capture(app, named: "banner-list")
        app.swipeUp()
        app.swipeDown()
        assertBanner(in: app)

        openConversation(in: app)
        let transcript = app.scrollViews["transcript.scrollView"].firstMatch
        XCTAssertTrue(transcript.appears(timeout: LossFixture.timeout), "A recent conversation reopens from memory")
        transcript.swipeDown()
        assertBanner(in: app)
        capture(app, named: "banner-conversation")
        tap(app.buttons["conversation.back"], in: app)
        XCTAssertTrue(app.staticTexts[LossFixture.agentName].firstMatch.appears(timeout: LossFixture.timeout))
        capture(app, named: "banner-workspace")

        openSpecNote(in: app)
        let status = app.buttons["Change status for Add usage summary endpoint"].firstMatch
        XCTAssertTrue(status.appears(timeout: LossFixture.timeout), "A recent note reopens from memory")
        XCTAssertFalse(status.isEnabled, "Task status changes need the Mac")
        assertBanner(in: app)
        capture(app, named: "banner-note")
        returnToWorkspaceList(in: app)

        app.openHomeAction("assistant")
        XCTAssertTrue(app.buttons["assistant.actions"].appears(timeout: LossFixture.timeout))
        XCTAssertTrue(app.scrollViews["transcript.scrollView"].firstMatch.appears(timeout: LossFixture.timeout))
        XCTAssertFalse(app.buttons["assistant.newConversation"].isEnabled, "A new conversation needs the Mac")
        assertBanner(in: app)
        capture(app, named: "banner-assistant")
    }

    @MainActor
    func testBannerExpandsWithGuidanceAndBackToHome() throws {
        for appearance in ["light", "dark"] {
            try expandBanner(appearance: appearance)
        }
    }

    @MainActor
    private func expandBanner(appearance: String) throws {
        let directory = try makeTriggerDirectory()
        let app = launch(directory: directory, arguments: ["--demo-connection-loss-reconnecting", "-appThemePreference", appearance])
        try trigger("loss", in: directory)
        let banner = assertBanner(in: app)
        assertBannerTitle("Reconnecting( to Demo Mac)?… · Read-only", in: app)
        XCTAssertFalse(app.buttons[LossFixture.bannerHomeIdentifier].exists, "Collapsed by default")
        capture(app, named: "banner-collapsed-\(appearance)")
        banner.tap()
        let home = app.buttons[LossFixture.bannerHomeIdentifier]
        XCTAssertTrue(home.appears(timeout: LossFixture.timeout))
        XCTAssertTrue(app.staticTexts["You can keep reading. Changes are turned off until the connection comes back."].exists)
        capture(app, named: "banner-expanded-\(appearance)")
        banner.tap()
        XCTAssertTrue(home.disappears(timeout: LossFixture.timeout), "Tapping again collapses the details")
        banner.tap()
        XCTAssertTrue(home.appears(timeout: LossFixture.timeout))
        home.tap()
        XCTAssertTrue(app.buttons["pairing.saved-connections"].appears(timeout: LossFixture.timeout))
        XCTAssertFalse(banner.exists, "Home leaves the remote UI and its banner")
    }

    @MainActor
    func testRecentlyViewedItemsReopenFromMemoryDuringDrop() throws {
        let directory = try makeTriggerDirectory()
        let app = launch(directory: directory, arguments: [
            "--demo-connection-loss-reconnecting", "--demo-connection-loss-hold-conversations"
        ])
        openConversation(in: app)
        XCTAssertTrue(app.scrollViews["transcript.scrollView"].firstMatch.appears(timeout: LossFixture.timeout))
        capture(app, named: "from-memory-before-loss")
        try trigger("loss", in: directory)
        assertBanner(in: app)
        tap(app.buttons["conversation.back"], in: app)
        returnToWorkspaceList(in: app)

        openConversation(in: app)
        XCTAssertTrue(
            app.scrollViews["transcript.scrollView"].firstMatch.appears(timeout: LossFixture.timeout),
            "A conversation read earlier shows its transcript from memory"
        )
        XCTAssertFalse(app.descendants(matching: .any)["read-only.unavailable"].exists)
        capture(app, named: "read-only-from-memory-conversation")
    }

    @MainActor
    func testOfflineDropNamesTheNetworkInsteadOfTheMac() throws {
        let directory = try makeTriggerDirectory()
        let app = launch(directory: directory, arguments: ["--demo-connection-loss-reconnecting"])
        try trigger("network-offline", in: directory)
        try trigger("loss", in: directory)
        assertBannerTitle("No network connection · Read-only", in: app)
        app.buttons[LossFixture.bannerIdentifier].tap()
        XCTAssertTrue(app.staticTexts["Check your Wi-Fi or cellular connection."].appears(timeout: LossFixture.timeout))
        capture(app, named: "banner-offline")
        try trigger("network-restored", in: directory)
        assertBannerTitle("Reconnecting( to Demo Mac)?… · Read-only", in: app)
    }

    @MainActor
    func testControlInventoryDuringDrop() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .phone, "Phone navigation; iPad shares the same controls")
        let directory = try makeTriggerDirectory()
        let app = launch(directory: directory, arguments: ["--demo-connection-loss-reconnecting"])
        openConversation(in: app)
        let composer = app.textViews["composer.textView"]
        XCTAssertTrue(composer.appears(timeout: LossFixture.timeout))
        try trigger("loss", in: directory)
        assertBanner(in: app)

        composer.tap()
        composer.typeText("Ask later")
        let send = app.buttons["Send Message"].firstMatch
        XCTAssertFalse(send.isEnabled, "Send")
        send.tap()
        XCTAssertTrue(app.descendants(matching: .any)["read-only.hint"].appears(timeout: LossFixture.timeout), "A tap explains why")
        capture(app, named: "read-only-send-hint")
        app.coordinate(withNormalizedOffset: LossFixture.readOnlyTapPoint).tap()
        XCTAssertTrue(app.buttons["Add Attachment"].firstMatch.isEnabled, "Attach (R1.13)")
        tap(app.buttons["conversation.actions.open"], in: app)
        for identifier in ["conversation.actions.model", "conversation.actions.rename", "conversation.actions.delete"] {
            let item = app.buttons[identifier]
            XCTAssertTrue(item.appears(timeout: LossFixture.timeout), identifier)
            XCTAssertFalse(item.isEnabled, identifier)
        }
        capture(app, named: "read-only-agent-menu")
        dismissMenu(in: app)
        XCTAssertTrue(app.buttons["conversation.back"].isEnabled, "Back (R1.13)")
        tap(app.buttons["conversation.back"], in: app)
        XCTAssertTrue(app.buttons["conversation.back"].disappears(timeout: LossFixture.timeout))

        tap(app.buttons["Workspace actions"], in: app)
        for label in ["Create New Agent", "Archive", "Delete"] {
            let item = app.buttons[label].firstMatch
            XCTAssertTrue(item.appears(timeout: LossFixture.timeout), label)
            XCTAssertFalse(item.isEnabled, label)
        }
        capture(app, named: "read-only-workspace-menu")
        dismissMenu(in: app)

        returnToWorkspaceList(in: app)
        tap(app.buttons["workspaces.menu"], in: app)
        let create = app.buttons["workspaces.menu.create"]
        XCTAssertTrue(create.appears(timeout: LossFixture.timeout))
        XCTAssertFalse(create.isEnabled, "New workspace")
        XCTAssertTrue(app.buttons["workspaces.menu.recentAgents"].isEnabled, "Navigation (R1.13)")
        dismissMenu(in: app)
        XCTAssertTrue(app.buttons["intent.menu.open"].isEnabled, "Home menu (R1.13)")
        app.openHomeAction("settings")
        XCTAssertTrue(app.buttons[LossFixture.bannerIdentifier].appears(timeout: LossFixture.timeout), "Settings opens during a drop")
        capture(app, named: "read-only-settings")
    }

    @MainActor
    func testStopAndQueuedMessagesAreReadOnlyDuringDrop() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .phone, "Workspace phone presentation")
        let directory = try makeTriggerDirectory()
        let app = launch(directory: directory, arguments: [
            "--demo-connection-loss-reconnecting", "--demo-design-scenario=queue"
        ])
        openDesignConversation(in: app)
        let stop = app.buttons["Stop response"].firstMatch
        XCTAssertTrue(stop.appears(timeout: LossFixture.timeout))
        let sendNow = app.buttons["Send queued message now"].firstMatch
        XCTAssertTrue(sendNow.appears(timeout: LossFixture.timeout))
        try trigger("loss", in: directory)
        assertBanner(in: app)
        XCTAssertFalse(stop.isEnabled, "Stop")
        for label in ["Send queued message now", "Edit queued message", "Remove queued message"] {
            XCTAssertFalse(app.buttons[label].firstMatch.isEnabled, label)
        }
        capture(app, named: "read-only-queue")
        try trigger("recover", in: directory)
        XCTAssertTrue(app.buttons[LossFixture.bannerIdentifier].disappears(timeout: LossFixture.timeout))
        let live = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: sendNow)
        XCTAssertEqual(XCTWaiter.wait(for: [live], timeout: LossFixture.timeout), .completed)
    }

    @MainActor
    func testQuestionsCannotBeSentOrDismissedDuringDrop() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .phone, "Workspace phone presentation")
        let directory = try makeTriggerDirectory()
        let app = launch(directory: directory, arguments: [
            "--demo-connection-loss-reconnecting", "--demo-design-scenario=question-flow"
        ])
        openDesignConversation(in: app)
        let dismiss = app.buttons["question.dismiss"]
        XCTAssertTrue(dismiss.appears(timeout: LossFixture.timeout))
        try trigger("loss", in: directory)
        assertBanner(in: app)
        XCTAssertFalse(dismiss.isEnabled, "Dismissing questions")
        let answer = app.buttons["question.answer"]
        XCTAssertTrue(answer.isEnabled, "Reading the questions stays available")
        capture(app, named: "read-only-questions")
    }

    // MARK: - Helpers

    @MainActor @discardableResult
    func assertBanner(in app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) -> XCUIElement {
        let banner = app.buttons[LossFixture.bannerIdentifier]
        XCTAssertTrue(banner.appears(timeout: LossFixture.timeout), file: file, line: line)
        XCTAssertTrue(banner.isHittable, file: file, line: line)
        XCTAssertTrue(banner.label.contains("Read-only"), "Banner says read-only: \(banner.label)", file: file, line: line)
        XCTAssertFalse(app.buttons[LossFixture.homeIdentifier].exists, "No blocking screen while reconnecting", file: file, line: line)
        return banner
    }

    @MainActor
    func assertStoppedTitle(in app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        let title = app.staticTexts.matching(NSPredicate(
            format: "identifier == %@ AND label MATCHES %@", "connection-loss.status", "Can’t reconnect( to Demo Mac)?"
        )).firstMatch
        XCTAssertTrue(title.appears(timeout: LossFixture.timeout), file: file, line: line)
    }

    @MainActor
    func assertBannerTitle(_ title: String, in app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        let banner = app.buttons.matching(NSPredicate(
            format: "identifier == %@ AND label MATCHES %@", LossFixture.bannerIdentifier, title
        )).firstMatch
        XCTAssertTrue(banner.appears(timeout: LossFixture.timeout), "Banner title: \(title)", file: file, line: line)
    }

    @MainActor
    func tap(_ element: XCUIElement, in app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(element.appears(timeout: LossFixture.timeout), app.debugDescription, file: file, line: line)
        element.tap()
    }

    @MainActor
    private func openSpecNote(in app: XCUIApplication) {
        tap(app.buttons["Context"].firstMatch, in: app)
        tap(app.staticTexts["Spec"].firstMatch, in: app)
        XCTAssertTrue(app.navigationBars["Spec"].appears(timeout: LossFixture.timeout))
    }

    @MainActor
    func returnToWorkspaceList(in app: XCUIApplication) {
        let search = app.buttons["workspaces.search.open"]
        for _ in 0..<LossFixture.backNavigationAttempts where !search.appears(timeout: LossFixture.backNavigationTimeout) {
            let back = app.buttons["workspaceDetail.back"].exists
                ? app.buttons["workspaceDetail.back"] : app.navigationBars.buttons.element(boundBy: 0)
            guard back.exists else { break }
            back.tap()
        }
        XCTAssertTrue(search.appears(timeout: LossFixture.timeout), "The workspace list never appeared")
    }

    @MainActor
    private func closeAssistant(in app: XCUIApplication) {
        let header = app.otherElements["assistant.header"].firstMatch
        XCTAssertTrue(header.appears(timeout: LossFixture.timeout))
        header.coordinate(withNormalizedOffset: CGVector(dx: LossFixture.horizontalCenter, dy: 0))
            .press(forDuration: LossFixture.dragHold, thenDragTo: app.coordinate(withNormalizedOffset: LossFixture.sheetDismissPoint))
        XCTAssertTrue(app.staticTexts[LossFixture.workspaceTitle].firstMatch.appears(timeout: LossFixture.timeout))
    }

    @MainActor
    private func openDesignConversation(in app: XCUIApplication) {
        tap(app.staticTexts["Workspace agent design"].firstMatch, in: app)
        tap(app.staticTexts["Continue Spec Writer"].firstMatch, in: app)
    }

    @MainActor
    private func dismissMenu(in app: XCUIApplication) {
        app.coordinate(withNormalizedOffset: LossFixture.menuDismissPoint).tap()
    }
}
