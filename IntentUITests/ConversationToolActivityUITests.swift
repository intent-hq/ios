import XCTest

nonisolated final class ConversationToolActivityUITests: XCTestCase {
    private static let timeout: TimeInterval = 30
    private static let minimumTapTarget: CGFloat = 44
    private static let frameTolerance: CGFloat = 1
    private static let toolLabels = ["Read design-system.astro", "Think", "Edit design-system.astro"]

    override func setUpWithError() throws {
        try super.setUpWithError()
        continueAfterFailure = false
    }

    override func tearDownWithError() throws {
        continueAfterFailure = true
        try super.tearDownWithError()
    }

    @MainActor
    func testIPadConsecutiveToolsExpandAndCollapseInBothThemes() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad, "iPad tool activity evidence")
        let app = XCUIApplication()
        addTeardownBlock { @MainActor [self] () async in
            if app.state == .runningForeground {
                capture(app, name: "iPad tools final state")
                app.terminate()
            }
            XCUIDevice.shared.orientation = .portrait
        }
        XCUIDevice.shared.orientation = .landscapeLeft
        for appearance in ["light", "dark"] {
            openTools(in: app, appearance: appearance)
            verifyTools(in: app, appearance: appearance)
            app.terminate()
        }
    }

    @MainActor
    private func openTools(in app: XCUIApplication, appearance: String) {
        app.launchArguments = [
            "--demo-data", "--demo-design-scenario=tools", "-appThemePreference", appearance,
            "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryL",
            "-AppleLanguages", "(en)", "-AppleLocale", "en_US"
        ]
        app.launch()
        let workspace = app.buttons["workspace.row.demo-ws-agent-design"]
        XCTAssertTrue(workspace.wait(for: \.isHittable, toEqual: true, timeout: Self.timeout))
        workspace.tap()
        let agent = app.buttons["workspace.agent.demo-agent-design"]
        XCTAssertTrue(agent.wait(for: \.isHittable, toEqual: true, timeout: Self.timeout))
        agent.tap()
        XCTAssertTrue(app.textViews["composer.textView"].waitForExistence(timeout: Self.timeout))
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: Self.timeout))
    }

    @MainActor
    private func verifyTools(in app: XCUIApplication, appearance: String) {
        let transcript = app.scrollViews["transcript.scrollView"].firstMatch
        XCTAssertTrue(transcript.waitForExistence(timeout: Self.timeout))
        let rows = Self.toolLabels.map { transcript.buttons[$0] }
        for row in rows {
            XCTAssertTrue(row.waitForExistence(timeout: Self.timeout))
        }
        let output = transcript.staticTexts.matching(NSPredicate(
            format: "label CONTAINS %@",
            "Use an outline for the error state."
        )).firstMatch
        XCTAssertFalse(output.exists, "Paired results must remain inside collapsed tool disclosures")
        assertCollapsedRows(rows, in: transcript)
        capture(app, name: "iPad tools collapsed \(appearance)")
        attachGeometry(rows, appearance: appearance)

        let read = rows[0]
        read.tap()
        XCTAssertTrue(waitUntil(timeout: Self.timeout) { read.value as? String == "Expanded" })
        XCTAssertTrue(output.waitForExistence(timeout: Self.timeout), "A physical tap must expose the paired output")
        XCTAssertTrue(waitUntil(timeout: Self.timeout) { isInside(output, transcript) && read.isHittable })
        XCTAssertNotNil(waitUntilSteady(timeout: Self.timeout, tolerance: Self.frameTolerance) { output.frame.midY })
        for row in rows.dropFirst() {
            XCTAssertEqual(row.value as? String, "Collapsed", "Expanding one tool must not expand its neighbors")
        }
        capture(app, name: "iPad tools expanded \(appearance)")

        read.tap()
        XCTAssertTrue(waitUntil(timeout: Self.timeout) { read.value as? String == "Collapsed" })
        XCTAssertTrue(output.waitForNonExistence(timeout: Self.timeout), "Collapsing must hide the paired output again")
        assertCollapsedRows(rows, in: transcript)
    }

    @MainActor
    private func assertCollapsedRows(_ rows: [XCUIElement], in transcript: XCUIElement) {
        XCTAssertTrue(waitUntil(timeout: Self.timeout) { rows.allSatisfy { $0.isHittable && isInside($0, transcript) } })
        for row in rows {
            XCTAssertEqual(row.value as? String, "Collapsed")
            XCTAssertNotNil(waitUntilSteady(timeout: Self.timeout, tolerance: Self.frameTolerance) { row.frame.midY })
            XCTAssertGreaterThanOrEqual(row.frame.height, Self.minimumTapTarget)
            XCTAssertGreaterThanOrEqual(row.frame.width, Self.minimumTapTarget)
        }
        for (previous, next) in zip(rows, rows.dropFirst()) {
            XCTAssertEqual(
                next.frame.minY,
                previous.frame.maxY,
                accuracy: Self.frameTolerance,
                "Consecutive tools must not gain extra spacing from padding or hidden result rows"
            )
        }
    }

    @MainActor
    private func attachGeometry(_ rows: [XCUIElement], appearance: String) {
        let measurements = rows.map { row in
            let text = row.staticTexts.firstMatch
            let textFrame = text.exists ? String(describing: text.frame) : "not separately exposed"
            return "\(row.label): button=\(row.frame), text=\(textFrame), value=\(String(describing: row.value))"
        }
        let attachment = XCTAttachment(
            string: "Native accessibility frames in points; text frames are not glyph bounds.\n"
                + "Figma reference: 20pt visible rows at y=0,36,72; 16pt visible gaps.\n"
                + measurements.joined(separator: "\n")
        )
        attachment.name = "iPad tools geometry \(appearance)"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    private func capture(_: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
