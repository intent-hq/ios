import XCTest

nonisolated final class IPadSidebarUITests: XCTestCase {
    private static let timeout: TimeInterval = 30
    private static let railSettleDuration: TimeInterval = 0.5
    private static let focusPanelWidth: CGFloat = 624
    private static let transcriptTapX: CGFloat = 0.02
    private static let backgroundRowTap = CGVector(dx: 0.1, dy: 0.2)
    private static let draft = "Keep this workspace draft"

    override func setUpWithError() throws {
        try super.setUpWithError()
        continueAfterFailure = false
    }

    override func tearDownWithError() throws {
        continueAfterFailure = true
        try super.tearDownWithError()
    }

    @MainActor
    func testSectionsAndPairingRestoreConversationInBothThemes() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad, "iPad sidebar navigation")
        XCUIDevice.shared.orientation = .landscapeLeft
        defer { XCUIDevice.shared.orientation = .portrait }
        for appearance in ["light", "dark"] {
            let app = launch(appearance: appearance, extraArguments: ["--demo-ipad-pane-geometry"])
            captureFirstWorkspaceSelection(in: app, appearance: appearance)
            openConversation(in: app)
            captureMainScreens(in: app, appearance: appearance)
            let background = try prepareTypingBackground(in: app)
            let composer = try app.textViews.matching(identifier: "composer.textView").singleHittableElement()
            let composerTap = try IPadFocusBackgroundTap(composer, in: app, recordsRestoration: true)
            try composerTap.activate(in: app)
            composer.typeText(Self.draft)
            try verifyTypingFocus(in: app, composer: composer, composerTap: composerTap, background: background, appearance: appearance)
            try verifyBackgroundNavigation(in: app, controls: background)
            XCTAssertEqual(try app.textViews.matching(identifier: "composer.textView").singleHittableElement().value as? String, Self.draft)
            try verifySections(in: app)
            try verifyPairingCancellation(in: app, appearance: appearance)
            XCTAssertEqual(try app.textViews.matching(identifier: "composer.textView").singleHittableElement().value as? String, Self.draft)
            app.terminate()
        }
    }

    @MainActor
    func testScrollingIndicatorStaysOutsideWorkspaceRowsInBothThemes() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad, "iPad sidebar scrolling")
        XCUIDevice.shared.orientation = .landscapeLeft
        defer { XCUIDevice.shared.orientation = .portrait }
        for appearance in ["light", "dark"] {
            let app = launch(appearance: appearance, extraArguments: ["--demo-long-workspace-list"])
            defer { app.terminate() }
            for mode in ["Recent", "Repo", "Status"] {
                let control = app.buttons["workspaces.viewMode.\(mode)"]
                control.tap()
                XCTAssertTrue(control.wait(for: \.isSelected, toEqual: true, timeout: Self.timeout))
                try verifyScrollingGutter(in: app, name: "iPad scrolling \(mode) sidebar \(appearance)")
            }
        }
    }

    @MainActor
    func testRailRemainsReachableWithAccessibilityText() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad, "iPad sidebar navigation")
        XCUIDevice.shared.orientation = .portrait
        let app = launch(appearance: "dark", accessibility: true)
        for destination in ["assistant", "workspaces", "connections", "settings"] {
            let button = app.buttons["ipad.rail.\(destination)"]
            waitForStableRailButton(button)
            XCTAssertTrue(button.isHittable)
            button.tap()
            XCTAssertTrue(button.wait(for: \.isSelected, toEqual: true, timeout: Self.timeout))
            XCTAssertTrue(app.buttons["ipad.rail.appearance"].isHittable)
        }
        let manual = app.buttons["settings.pairing.manual"]
        XCTAssertTrue(manual.waitForExistence(timeout: Self.timeout))
        let settings = app.scrollViews["settings.scroll"]
        for _ in 0..<3 where !manual.isHittable { settings.swipeUp() }
        capture(app, name: "iPad accessibility Settings")
        XCTAssertTrue(manual.isHittable, app.debugDescription)
        manual.tap()
        XCTAssertTrue(app.textFields["manual.host"].waitForExistence(timeout: Self.timeout))
        capture(app, name: "iPad accessibility manual pairing")
        XCTAssertTrue(app.buttons["ipad.pairing.cancel"].isHittable, app.debugDescription)
        app.buttons["ipad.pairing.cancel"].tap()
        XCTAssertTrue(app.buttons["ipad.rail.workspaces"].isHittable)
    }

    @MainActor
    func testRepeatedAgentSelectionReturnsFromChildAndPreservesDraft() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad, "iPad retained conversation navigation")
        XCUIDevice.shared.orientation = .landscapeLeft
        defer { XCUIDevice.shared.orientation = .portrait }
        let trigger = FileManager.default.temporaryDirectory.appendingPathComponent("ipad-reselect-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: trigger) }
        let app = launch(appearance: "light", extraArguments: ["--demo-conversation-reselection-trigger-file=\(trigger.path)"])
        defer { app.terminate() }
        let workspace = app.buttons["workspace.row.demo-ws-flaky-tests"]
        XCTAssertTrue(workspace.waitForExistence(timeout: Self.timeout))
        workspace.tap()
        let agent = app.buttons["workspace.agent.demo-agent-deflake"]
        XCTAssertTrue(agent.waitForExistence(timeout: Self.timeout))
        agent.tap()
        let composer = app.textViews["composer.textView"]
        XCTAssertTrue(composer.waitForExistence(timeout: Self.timeout))
        composer.tap()
        composer.typeText(Self.draft)
        let child = app.buttons["watched-agent-demo-agent-deflake-capture"]
        app.buttons["ipad.focus.close"].tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: Self.timeout))
        XCTAssertTrue(child.wait(for: \.isHittable, toEqual: true, timeout: Self.timeout))
        child.tap()
        let childTitle = app.staticTexts["Capture Race Fixer, Agent"]
        XCTAssertTrue(childTitle.wait(for: \.isHittable, toEqual: true, timeout: Self.timeout))
        app.buttons["ipad.rail.settings"].tap()
        app.buttons["ipad.rail.workspaces"].tap()
        XCTAssertTrue(childTitle.isHittable, "Section changes must retain the pushed conversation")
        try Data().write(to: trigger)
        // The reselected parent is named by its highlighted sidebar row rather than a header title.
        XCTAssertTrue(childTitle.waitForNonExistence(timeout: Self.timeout))
        XCTAssertTrue(agent.wait(for: \.isSelected, toEqual: true, timeout: Self.timeout))
        XCTAssertEqual(try app.textViews.matching(identifier: "composer.textView").singleHittableElement().value as? String, Self.draft)
        XCTAssertTrue(app.buttons["ipad.rail.workspaces"].isSelected)
    }

    @MainActor
    func testRepeatedSidebarTogglesWithAgentHistoryPreserveDraft() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad, "iPad sidebar toggling")
        XCUIDevice.shared.orientation = .landscapeLeft
        defer { XCUIDevice.shared.orientation = .portrait }
        let app = launch(appearance: "dark", extraArguments: ["--demo-settings"])
        defer { app.terminate() }
        openConversation(in: app)
        let composer = try app.textViews.matching(identifier: "composer.textView").singleHittableElement()
        composer.tap()
        composer.typeText(Self.draft)
        app.buttons["ipad.focus.close"].tap()
        XCTAssertTrue(app.buttons["ipad.rail.workspaces"].wait(for: \.isHittable, toEqual: true, timeout: Self.timeout))
        verifyPopulatedHistory(in: app)
        let expand = app.buttons["ipad.sidebar.expand"]
        for _ in 0..<12 {
            app.hideWorkspaceSidebar()
            XCTAssertTrue(expand.wait(for: \.isHittable, toEqual: true, timeout: Self.timeout))
            expand.tap()
        }
        XCTAssertTrue(app.buttons["Workspace actions"].firstMatch.wait(for: \.isHittable, toEqual: true, timeout: Self.timeout))
        // History reopened the conversation, so resolve its composer again.
        XCTAssertEqual(try app.textViews.matching(identifier: "composer.textView").singleHittableElement().value as? String, Self.draft)
        verifyPopulatedHistory(in: app)
    }

    @MainActor
    private func verifyTypingFocus(in app: XCUIApplication, composer: XCUIElement, composerTap: IPadFocusBackgroundTap, background: TypingBackgroundControls, appearance: String) throws {
        let close = app.buttons["ipad.focus.close"]
        XCTAssertTrue(close.wait(for: \.isHittable, toEqual: true, timeout: Self.timeout))
        capture(app, name: "iPad focused typing \(appearance)")
        let panel = try IPadFocusBackgroundTap.paneFrame("ipad.detail.panel", in: app)
        XCTAssertEqual(panel.width, Self.focusPanelWidth, accuracy: 2, app.debugDescription)
        XCTAssertEqual(panel.midX, app.windows.firstMatch.frame.midX, accuracy: 2, app.debugDescription)
        // The header is conditionally removed; retained background panes need an input test.
        XCTAssertFalse(app.buttons["conversation.back"].exists)
        XCTAssertEqual(app.textViews.matching(identifier: "composer.textView").allElementsBoundByIndex.filter { $0.isHittable }.count, 1)
        XCTAssertTrue(try app.buttons.matching(identifier: "composer.send").singleHittableElement().isHittable)
        XCTAssertTrue(try app.buttons.matching(identifier: "composer.attachment").singleHittableElement().isHittable)
        let keyboard = app.keyboards.firstMatch
        XCTAssertTrue(keyboard.waitForExistence(timeout: Self.timeout))
        XCTAssertLessThanOrEqual(close.frame.maxY, keyboard.frame.minY)
        try verifyBlockedTypingBackground(in: app, controls: background, panel: panel)
        let transcript = try app.scrollViews.matching(identifier: "transcript.scrollView").singleHittableElement()
        transcript.coordinate(withNormalizedOffset: CGVector(dx: Self.transcriptTapX, dy: 0.5)).tap()
        XCTAssertTrue(keyboard.waitForNonExistence(timeout: Self.timeout))
        XCTAssertTrue(close.waitForNonExistence(timeout: Self.timeout), "Hiding the keyboard must restore the normal pane")
        XCTAssertEqual(composer.value as? String, Self.draft)
        capture(app, name: "iPad focused typing keyboard hidden \(appearance)")
        try composerTap.activate(in: app)
        XCTAssertTrue(close.wait(for: \.isHittable, toEqual: true, timeout: Self.timeout))
        XCUIDevice.shared.orientation = .portrait
        XCTAssertTrue(close.wait(for: \.isHittable, toEqual: true, timeout: Self.timeout))
        XCTAssertEqual(composer.value as? String, Self.draft)
        XCTAssertTrue(close.isHittable)
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(close.wait(for: \.isHittable, toEqual: true, timeout: Self.timeout))
        close.tap()
        XCTAssertTrue(close.waitForNonExistence(timeout: Self.timeout))
        capture(app, name: "iPad typing restored \(appearance)")
        XCTAssertTrue(app.buttons["ipad.rail.workspaces"].isSelected)
        XCTAssertTrue(app.buttons["workspace.agent.demo-agent-implementor"].wait(for: \.isSelected, toEqual: true, timeout: Self.timeout))
        XCTAssertEqual(composer.value as? String, Self.draft)
        verifyComposerAfterSearch(in: app, composer: composer, composerTap: composerTap, appearance: appearance)
    }

    @MainActor
    private func verifyPopulatedHistory(in app: XCUIApplication) {
        let reopensConversation = showWorkspaceList(in: app)
        app.buttons["workspaces.menu"].tap()
        app.buttons["workspaces.menu.recentAgents"].tap()
        let entry = app.buttons.matching(NSPredicate(
            format: "identifier BEGINSWITH %@ AND identifier ENDSWITH %@",
            "agent-history.entry.",
            "/demo-agent-implementor"
        )).firstMatch
        XCTAssertTrue(entry.wait(for: \.isHittable, toEqual: true, timeout: Self.timeout))
        let close = app.buttons["agent-history.close"]
        close.tap()
        XCTAssertTrue(close.waitForNonExistence(timeout: Self.timeout))
        if reopensConversation { openConversation(in: app) }
    }

    @MainActor
    private func captureFirstWorkspaceSelection(in app: XCUIApplication, appearance: String) {
        let recent = app.buttons["workspaces.viewMode.Recent"]
        recent.tap()
        XCTAssertTrue(recent.wait(for: \.isSelected, toEqual: true, timeout: Self.timeout))
        let workspace = app.buttons["workspace.row.demo-ws-reconnect"]
        XCTAssertTrue(workspace.wait(for: \.isHittable, toEqual: true, timeout: Self.timeout))
        workspace.tap()
        let heading = app.staticTexts["workspace.title.heading"]
        XCTAssertTrue(heading.wait(for: \.label, toEqual: "Fix websocket reconnect storm", timeout: Self.timeout))
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: Self.timeout))
        capture(app, name: "iPad first workspace selected \(appearance)")
    }

    @MainActor
    private func captureMainScreens(in app: XCUIApplication, appearance: String) {
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: Self.timeout))
        showWorkspaceList(in: app)
        for mode in ["Repo", "Status", "Recent"] {
            let control = app.buttons["workspaces.viewMode.\(mode)"]
            control.tap()
            XCTAssertTrue(control.wait(for: \.isSelected, toEqual: true, timeout: Self.timeout))
            capture(app, name: "iPad \(mode) sidebar \(appearance)")
        }
        capture(app, name: "iPad workspace \(appearance)")
        app.buttons["ipad.sidebar.collapse"].tap()
        XCTAssertTrue(app.buttons["ipad.sidebar.expand"].waitForExistence(timeout: Self.timeout))
        capture(app, name: "iPad collapsed \(appearance)")
        app.buttons["ipad.sidebar.expand"].tap()
        let sections = [
            ("assistant", "Assistant", "assistant.sidebar.newConversation"),
            ("connections", "connections", "saved-connections.scan"),
            ("settings", "settings", "settings.pairing.scan")
        ]
        for (section, label, control) in sections {
            app.buttons["ipad.rail.\(section)"].tap()
            XCTAssertTrue(app.buttons["ipad.rail.\(section)"].wait(for: \.isSelected, toEqual: true, timeout: Self.timeout))
            capture(app, name: "iPad \(label) \(appearance)")
            XCTAssertTrue(app.buttons[control].wait(for: \.isHittable, toEqual: true, timeout: Self.timeout), app.debugDescription)
            XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: Self.timeout))
            app.buttons["ipad.rail.workspaces"].tap()
        }
    }

    @MainActor
    private func verifySections(in app: XCUIApplication) throws {
        app.buttons["ipad.rail.assistant"].tap()
        XCTAssertTrue(app.buttons["assistant.sidebar.newConversation"].waitForExistence(timeout: Self.timeout))
        XCTAssertEqual(try app.textViews.matching(identifier: "composer.textView").singleHittableElement().value as? String, "")
        app.buttons["ipad.rail.workspaces"].tap()
        let composer = try app.textViews.matching(identifier: "composer.textView").singleHittableElement()
        XCTAssertEqual(composer.value as? String, Self.draft)
        for section in ["connections", "settings"] {
            app.buttons["ipad.rail.\(section)"].tap()
            XCTAssertTrue(app.buttons["ipad.rail.\(section)"].isSelected)
            XCTAssertEqual(composer.value as? String, Self.draft)
        }
    }

    @MainActor
    private func verifyPairingCancellation(in app: XCUIApplication, appearance: String) throws {
        app.buttons["settings.pairing.scan"].tap()
        let cancel = app.buttons["ipad.pairing.cancel"]
        XCTAssertTrue(cancel.waitForExistence(timeout: Self.timeout))
        XCTAssertFalse(app.textViews.matching(identifier: "composer.textView").allElementsBoundByIndex.contains { $0.isHittable })
        XCTAssertTrue(app.buttons["ipad.rail.connections"].isHittable)
        capture(app, name: "iPad QR \(appearance)")
        cancel.tap()
        XCTAssertEqual(try app.textViews.matching(identifier: "composer.textView").singleHittableElement().value as? String, Self.draft)
        app.buttons["settings.pairing.manual"].tap()
        let host = app.textFields["manual.host"]
        XCTAssertTrue(host.waitForExistence(timeout: Self.timeout))
        host.tap()
        host.typeText("example.local")
        XCTAssertTrue(cancel.isHittable)
        capture(app, name: "iPad manual \(appearance)")
        cancel.tap()
        XCTAssertEqual(try app.textViews.matching(identifier: "composer.textView").singleHittableElement().value as? String, Self.draft)
        XCTAssertFalse(host.exists)
        app.buttons["ipad.rail.workspaces"].tap()
    }

    @MainActor
    private func launch(appearance: String, accessibility: Bool = false, extraArguments: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--demo-data", "-appThemePreference", appearance] + extraArguments
        if accessibility {
            app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        }
        app.launch()
        // Only the ordinary iPad shell keeps the global rail; the unfolded Duo uses the launcher.
        let navigation = UIDevice.current.userInterfaceIdiom == .pad ? "ipad.rail.workspaces" : "intent.menu.open"
        XCTAssertTrue(app.buttons[navigation].waitForExistence(timeout: Self.timeout))
        return app
    }

    @MainActor
    private func openConversation(in app: XCUIApplication) {
        let workspace = app.staticTexts["Add usage analytics dashboard"].firstMatch
        XCTAssertTrue(workspace.waitForExistence(timeout: Self.timeout))
        workspace.tap()
        let agent = app.buttons["workspace.agent.demo-agent-implementor"]
        XCTAssertTrue(agent.waitForExistence(timeout: Self.timeout))
        agent.tap()
        XCTAssertTrue(app.textViews["composer.textView"].waitForExistence(timeout: Self.timeout))
    }

    @MainActor
    private func capture(_: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

extension IPadSidebarUITests {
    /// An open conversation moves its workspace into the persistent sidebar; the
    /// conversation's Back restores the list. Returns whether a conversation was closed.
    @MainActor
    @discardableResult
    private func showWorkspaceList(in app: XCUIApplication) -> Bool {
        let back = app.buttons["conversation.back"]
        let closesConversation = back.exists && back.isHittable
        if closesConversation { back.tap() }
        XCTAssertTrue(app.collectionViews["workspaces.list"].wait(for: \.isHittable, toEqual: true, timeout: Self.timeout))
        return closesConversation
    }

    @MainActor
    private func waitForHittableComposer(in app: XCUIApplication) -> Bool {
        waitUntil(timeout: Self.timeout) {
            app.textViews.matching(identifier: "composer.textView").allElementsBoundByIndex.contains(where: \.isHittable)
        }
    }

    @MainActor
    private func verifyComposerAfterSearch(in app: XCUIApplication, composer: XCUIElement, composerTap: IPadFocusBackgroundTap, appearance: String) {
        let reopensConversation = showWorkspaceList(in: app)
        app.buttons["workspaces.search.open"].tap()
        let search = app.textFields["workspaces.search.field"]
        XCTAssertTrue(search.waitForExistence(timeout: Self.timeout))
        search.typeText("payment")
        app.buttons["workspaces.search.cancel"].tap()
        if reopensConversation { openConversation(in: app) }
        let restored = reopensConversation
            ? waitForHittableComposer(in: app)
            : composer.wait(for: \.isHittable, toEqual: true, timeout: Self.timeout)
        if !restored {
            composerTap.recordRestorationFailure(in: app, name: "iPad composer search restoration failure \(appearance)") {
                app.buttons["ipad.focus.close"].exists && app.keyboards.firstMatch.exists
            }
        }
        XCTAssertTrue(restored, "The original post-search composer restoration must pass before any diagnostic gesture")
        let current = reopensConversation ? try? app.textViews.matching(identifier: "composer.textView").singleHittableElement() : composer
        XCTAssertEqual(current?.value as? String, Self.draft, "Search cancellation must retain the current conversation draft")
    }

    private struct TypingBackgroundControls {
        let connections: IPadFocusBackgroundTap
        let workspace: IPadFocusBackgroundTap
    }

    @MainActor
    private func prepareTypingBackground(in app: XCUIApplication) throws -> TypingBackgroundControls {
        let controls = try TypingBackgroundControls(
            connections: IPadFocusBackgroundTap(app.buttons["ipad.rail.connections"], in: app),
            workspace: IPadFocusBackgroundTap(app.buttons["workspace.row.demo-ws-reconnect"], in: app, position: Self.backgroundRowTap)
        )
        try verifyBackgroundNavigation(in: app, controls: controls)
        return controls
    }

    @MainActor
    private func verifyBackgroundNavigation(in app: XCUIApplication, controls: TypingBackgroundControls) throws {
        try controls.connections.activate(in: app)
        XCTAssertTrue(app.buttons["ipad.rail.connections"].wait(for: \.isSelected, toEqual: true, timeout: Self.timeout))
        XCTAssertTrue(app.buttons["saved-connections.scan"].wait(for: \.isHittable, toEqual: true, timeout: Self.timeout))
        app.buttons["ipad.rail.workspaces"].tap()
        XCTAssertTrue(app.buttons["ipad.rail.workspaces"].wait(for: \.isSelected, toEqual: true, timeout: Self.timeout))
        showWorkspaceList(in: app)
        try controls.workspace.activate(in: app)
        XCTAssertTrue(app.staticTexts["workspace.title.heading"].wait(for: \.label, toEqual: "Fix websocket reconnect storm", timeout: Self.timeout))
        openConversation(in: app)
        XCTAssertTrue(app.buttons["workspace.agent.demo-agent-implementor"].wait(for: \.isSelected, toEqual: true, timeout: Self.timeout))
    }

    @MainActor
    private func verifyBlockedTypingBackground(in app: XCUIApplication, controls: TypingBackgroundControls, panel: CGRect) throws {
        // Calibrated native tests preserve editor identity/selection. Snapshot counts
        // include retained editors and cannot establish VoiceOver traversal.
        for control in [controls.connections, controls.workspace] {
            try control.assertBlocked(in: app, focusedPane: panel) {
                let editors = app.textViews.matching(identifier: "composer.textView").allElementsBoundByIndex.filter { $0.isHittable }
                return app.buttons["ipad.focus.close"].isHittable
                    && editors.count == 1 && editors.first?.value as? String == Self.draft
                    && app.keyboards.firstMatch.exists
                    && !app.buttons["conversation.back"].exists
            }
        }
    }

    @MainActor
    private func verifyScrollingGutter(in app: XCUIApplication, name: String) throws {
        let list = app.collectionViews["workspaces.list"]
        XCTAssertTrue(list.wait(for: \.isHittable, toEqual: true, timeout: Self.timeout))
        let rows = list.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "workspace.row."))
        let firstRow = try XCTUnwrap(rows.allElementsBoundByIndex.first { $0.isHittable })
        let firstIdentifier = firstRow.identifier
        list.swipeUp(velocity: .slow)
        capture(app, name: name)
        let hierarchy = XCTAttachment(string: app.debugDescription)
        hierarchy.name = "\(name) hierarchy"
        hierarchy.lifetime = .keepAlways
        add(hierarchy)
        let visibleRow = try XCTUnwrap(rows.allElementsBoundByIndex.first { $0.isHittable })
        XCTAssertNotEqual(visibleRow.identifier, firstIdentifier, "The long-list fixture must actually scroll")
        let indicator = list.otherElements.matching(NSPredicate(format: "label BEGINSWITH %@", "Vertical scroll bar")).firstMatch
        XCTAssertTrue(indicator.exists, "The overflowing list must expose its native scroll indicator")
        // AX expands the thumb's hit target; compare its outer edge, then inspect the screenshot for the visible track.
        XCTAssertGreaterThan(indicator.frame.maxX, visibleRow.frame.maxX, app.debugDescription)
        XCTAssertLessThanOrEqual(indicator.frame.maxX, list.frame.maxX + 1, app.debugDescription)
    }
}

extension IPadSidebarUITests {
    @MainActor
    private func waitForStableRailButton(_ button: XCUIElement) {
        var previousFrame: CGRect?
        var stableSince = Date()
        let settled = waitUntil(timeout: Self.timeout) {
            guard button.exists, button.isEnabled, button.isHittable else {
                previousFrame = nil
                stableSince = Date()
                return false
            }
            let currentFrame = button.frame
            if currentFrame != previousFrame {
                previousFrame = currentFrame
                stableSince = Date()
            }
            return Date().timeIntervalSince(stableSince) >= Self.railSettleDuration
        }
        XCTAssertTrue(settled, "Rail button must stop moving before the physical tap")
    }
}

extension IPadSidebarUITests {
    @MainActor
    func testExpandedDuoUsesSharedShellAndChatHeader() throws {
        try XCTSkipUnless(
            UIDevice.current.userInterfaceIdiom == .pad || ProcessInfo.processInfo.environment["INTENT_UITEST_UNFOLDED_DUO"] == "1",
            "Requires iPad or an unfolded Duo"
        )
        XCUIDevice.shared.orientation = .landscapeLeft
        defer { XCUIDevice.shared.orientation = .portrait }
        for appearance in ["light", "dark"] {
            let app = launch(appearance: appearance, extraArguments: ["--demo-ipad-pane-geometry"])
            openConversation(in: app)
            let header = app.buttons["conversation.back"]
            XCTAssertTrue(header.waitForExistence(timeout: Self.timeout))
            let transcript = app.scrollViews["transcript.scrollView"]
            XCTAssertTrue(transcript.waitForExistence(timeout: Self.timeout))
            let headerFrame = header.frame
            transcript.swipeDown()
            XCTAssertEqual(header.frame, headerFrame)
            XCTAssertTrue(header.isHittable)
            let usesDuoLauncher = UIDevice.current.userInterfaceIdiom != .pad
            XCTAssertEqual(app.buttons["ipad.rail.workspaces"].exists, !usesDuoLauncher)
            XCTAssertEqual(app.buttons["intent.menu.open"].exists, usesDuoLauncher)
            capture(app, name: "Shared shell chat scrollback \(appearance)")
            if usesDuoLauncher {
                // The unfolded Duo reaches sections through the launcher instead of the rail.
                app.openHomeAction("settings")
                app.openHomeAction("workspaces")
            } else {
                app.buttons["ipad.rail.settings"].tap()
                app.buttons["ipad.rail.workspaces"].tap()
            }
            XCTAssertTrue(app.textViews["composer.textView"].waitForExistence(timeout: Self.timeout))
            app.terminate()
        }
    }
}
