import XCTest

nonisolated final class ConversationMermaidUITests: XCTestCase {
    private enum Fixture {
        static let timeout: TimeInterval = 20
        static let minimumTapHeight: CGFloat = 44
        static let edgeInset: CGFloat = 6
        static let minimumZoomRatio: CGFloat = 1.2
        static let minimumPanPercentage = 2.0
        static let viewportInset: CGFloat = 12
        static let maximumScrolls = 12
        static let transcriptDragX: CGFloat = 0.02
        static let dragNear: CGFloat = 0.25
        static let dragFar: CGFloat = 0.75
        static let dragDuration: TimeInterval = 0.05
        static let dragHold: TimeInterval = 0.2
        static let historyVisits = 3
        static let growthMessages = 5
    }

    @MainActor
    func testDiagramHistoryReopensAndGoToEndShowsLastAnswer() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments += ["--demo-data", "--demo-design-scenario=mermaid-history", "--trace-conversation"]
        app.launch()
        defer { app.terminate() }
        let workspace = app.staticTexts["Workspace agent design"].firstMatch
        XCTAssertTrue(workspace.waitForExistence(timeout: Fixture.timeout))
        workspace.tap()

        for visit in 1...Fixture.historyVisits {
            let agent = app.staticTexts["Continue Spec Writer"].firstMatch
            XCTAssertTrue(agent.waitForExistence(timeout: Fixture.timeout))
            agent.tap()
            let transcript = app.scrollViews["transcript.scrollView"].firstMatch
            XCTAssertTrue(transcript.waitForExistence(timeout: Fixture.timeout))
            let lastAnswer = transcript.staticTexts.matching(NSPredicate(
                format: "label CONTAINS %@", "Architecture answer 4 is complete."
            )).firstMatch
            let goToEnd = app.buttons["transcript.goToEnd"].firstMatch
            XCTAssertTrue(waitUntil(timeout: Fixture.timeout) { goToEnd.exists || lastAnswer.isHittable })
            if goToEnd.exists { goToEnd.tap() }
            let landed = waitUntil(timeout: Fixture.timeout) {
                guard lastAnswer.exists, lastAnswer.isHittable else { return false }
                return transcript.frame.intersects(lastAnswer.frame) && !goToEnd.exists
            }
            capture(app, name: "mermaid-history-visit-\(visit)")
            XCTAssertTrue(landed, "The final answer must be visible without a manual scroll: \(transcript.value ?? "no report")")
            app.buttons["conversation.back"].tap()
            if visit < Fixture.historyVisits {
                visitOtherWorkspace(in: app)
                XCTAssertTrue(workspace.waitForExistence(timeout: Fixture.timeout))
                workspace.tap()
            }
        }
    }

    @MainActor
    func testDiagramHistoryRemainsUsableWhenItGrowsPastEagerLimit() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments += ["--demo-data", "--demo-design-scenario=mermaid-history", "--trace-conversation"]
        app.launch()
        defer { app.terminate() }
        let workspace = app.staticTexts["Workspace agent design"].firstMatch
        XCTAssertTrue(workspace.waitForExistence(timeout: Fixture.timeout))
        workspace.tap()
        let agent = app.staticTexts["Continue Spec Writer"].firstMatch
        XCTAssertTrue(agent.waitForExistence(timeout: Fixture.timeout))
        agent.tap()
        let transcript = app.scrollViews["transcript.scrollView"]
        XCTAssertTrue(transcript.waitForExistence(timeout: Fixture.timeout))
        for index in 1...Fixture.growthMessages {
            let composer = app.textViews["composer.textView"]
            composer.tap()
            composer.typeText("Diagram follow-up \(index)")
            app.buttons["composer.send"].tap()
            let stop = app.buttons["composer.stop"]
            XCTAssertTrue(stop.waitForExistence(timeout: Fixture.timeout))
            stop.tap()
            XCTAssertTrue(stop.waitForNonExistence(timeout: Fixture.timeout))
        }
        let lastMessage = transcript.staticTexts["Diagram follow-up \(Fixture.growthMessages)"].firstMatch
        XCTAssertTrue(waitUntil(timeout: Fixture.timeout) {
            lastMessage.isHittable && transcript.frame.intersects(lastMessage.frame)
                && !app.buttons["transcript.goToEnd"].exists
        }, "Growing past the eager limit must retain the live end: \(transcript.value ?? "no report")")
        capture(app, name: "mermaid-history-grown")
    }

    @MainActor
    private func visitOtherWorkspace(in app: XCUIApplication) {
        let back = app.buttons["workspaceDetail.back"]
        XCTAssertTrue(back.waitForExistence(timeout: Fixture.timeout))
        back.tap()
        let otherWorkspace = app.staticTexts["Deflake payment integration tests"].firstMatch
        XCTAssertTrue(otherWorkspace.waitForExistence(timeout: Fixture.timeout))
        otherWorkspace.tap()
        let otherAgent = app.staticTexts["Test Stabilizer"].firstMatch
        XCTAssertTrue(otherAgent.waitForExistence(timeout: Fixture.timeout))
        otherAgent.tap()
        XCTAssertTrue(app.scrollViews["transcript.scrollView"].waitForExistence(timeout: Fixture.timeout))
        app.buttons["conversation.back"].tap()
        XCTAssertTrue(back.waitForExistence(timeout: Fixture.timeout))
        back.tap()
    }

    @MainActor
    func testFullscreenButtonEdgeAndInlinePinchAndPan() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments += ["--demo-data", "--demo-design-scenario=mermaid"]
        app.launch()
        // XCTest assertion aborts can bypass Swift defer blocks.
        addTeardownBlock { @MainActor [self] () async in
            capture(app, name: "mermaid-final-state")
            app.terminate()
        }
        let workspace = app.staticTexts["Workspace agent design"].firstMatch
        XCTAssertTrue(workspace.waitForExistence(timeout: Fixture.timeout))
        workspace.tap()
        let agent = app.staticTexts["Continue Spec Writer"].firstMatch
        XCTAssertTrue(agent.waitForExistence(timeout: Fixture.timeout))
        agent.tap()
        let transcript = app.scrollViews["transcript.scrollView"].firstMatch
        XCTAssertTrue(transcript.waitForExistence(timeout: Fixture.timeout))
        let webView = transcript.webViews["mermaid.webview"].firstMatch
        let expand = transcript.buttons["mermaid.expand"].firstMatch
        XCTAssertTrue(webView.waitForExistence(timeout: Fixture.timeout))
        XCTAssertTrue(expand.waitForExistence(timeout: Fixture.timeout))
        reveal(webView, expand: expand, in: transcript)
        let diagram = webView.images["Mermaid diagram"].firstMatch
        XCTAssertTrue(diagram.waitForExistence(timeout: Fixture.timeout), "WebKit must expose the rendered SVG for gesture assertions")
        capture(app, name: "mermaid-inline-before-gestures")
        XCTAssertGreaterThan(diagram.frame.width, webView.frame.width, "The fixture must overflow horizontally")
        XCTAssertGreaterThan(diagram.frame.height, webView.frame.height, "The fixture must overflow vertically")
        XCTAssertFalse(app.buttons["View source"].exists)
        verifyFullscreen(in: app, expand: expand, webView: webView)
        reveal(webView, expand: expand, in: transcript)
        try verifyPinch(in: app, diagram: diagram, webView: webView)
        try verifyPan(in: app, webView: webView)
        XCTAssertFalse(app.buttons["mermaid.done"].exists, "Pinch and pan must work without opening fullscreen")
        XCTAssertTrue(expand.exists, "The diagram must remain embedded in the conversation")
    }

    @MainActor
    private func verifyFullscreen(in app: XCUIApplication, expand: XCUIElement, webView: XCUIElement) {
        XCTAssertGreaterThanOrEqual(expand.frame.height, Fixture.minimumTapHeight)
        XCTAssertGreaterThanOrEqual(expand.frame.width, webView.frame.width - Fixture.edgeInset)
        // The far edge is outside the label/icon; tapping the center would miss this regression.
        expand.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: expand.frame.width - Fixture.edgeInset, dy: expand.frame.height / 2))
            .tap()
        let done = app.buttons["mermaid.done"].firstMatch
        XCTAssertTrue(done.waitForExistence(timeout: Fixture.timeout), "The button's outer edge must open fullscreen")
        let expandedDiagram = app.webViews["mermaid.fullscreen.webview"].images["Mermaid diagram"].firstMatch
        let rendered = expandedDiagram.waitForExistence(timeout: Fixture.timeout)
        capture(app, name: "mermaid-fullscreen-from-button-edge")
        XCTAssertTrue(rendered, "The fullscreen renderer must draw its own diagram")
        done.tap()
        XCTAssertTrue(done.waitForNonExistence(timeout: Fixture.timeout))
        XCTAssertTrue(webView.waitForExistence(timeout: Fixture.timeout))
    }

    @MainActor
    private func verifyPinch(in app: XCUIApplication, diagram: XCUIElement, webView: XCUIElement) throws {
        let before = try XCTUnwrap(frame(of: diagram), "The rendered SVG needs observable bounds before pinch")
        webView.pinch(withScale: 2, velocity: 1)
        let zoomed = waitUntil(timeout: Fixture.timeout) {
            guard let after = frame(of: diagram) else { return false }
            return after.width > before.width * Fixture.minimumZoomRatio
                && after.height > before.height * Fixture.minimumZoomRatio
        }
        capture(app, name: "mermaid-inline-after-pinch")
        XCTAssertTrue(zoomed, "A native pinch must enlarge the actual SVG in both axes; unchanged or clipped bounds cannot prove zoom")
    }

    @MainActor
    private func verifyPan(in app: XCUIApplication, webView: XCUIElement) throws {
        let viewport = webView.frame
        let beforeHorizontal = try XCTUnwrap(scrollPosition(in: webView, axis: "Horizontal"))
        drag(webView, from: CGVector(dx: Fixture.dragFar, dy: 0.5), to: CGVector(dx: Fixture.dragNear, dy: 0.5))
        let pannedHorizontally = waitUntil(timeout: Fixture.timeout) {
            guard let after = scrollPosition(in: webView, axis: "Horizontal") else { return false }
            return after > beforeHorizontal + Fixture.minimumPanPercentage
        }
        capture(app, name: "mermaid-inline-after-horizontal-pan")
        XCTAssertTrue(pannedHorizontally, "Dragging left must move the SVG inside its web view")

        let beforeVertical = try XCTUnwrap(scrollPosition(in: webView, axis: "Vertical"))
        drag(webView, from: CGVector(dx: 0.5, dy: Fixture.dragFar), to: CGVector(dx: 0.5, dy: Fixture.dragNear))
        let pannedVertically = waitUntil(timeout: Fixture.timeout) {
            guard let after = scrollPosition(in: webView, axis: "Vertical") else { return false }
            return after > beforeVertical + Fixture.minimumPanPercentage
        }
        capture(app, name: "mermaid-inline-after-vertical-pan")
        XCTAssertTrue(pannedVertically, "Dragging up must move the SVG relative to its web view, not just scroll the transcript")
        XCTAssertEqual(webView.frame, viewport, "Chart gestures must not move the transcript viewport")
    }

    @MainActor
    private func scrollPosition(in webView: XCUIElement, axis: String) -> Double? {
        // WebKit clamps offscreen SVG origins, but its own scroll indicator reports the actual position.
        let indicator = webView.otherElements.matching(
            NSPredicate(format: "label BEGINSWITH %@", "\(axis) scroll bar,")
        ).firstMatch
        guard indicator.exists, let value = indicator.value as? String else { return nil }
        return Double(value.replacingOccurrences(of: "%", with: ""))
    }

    @MainActor
    private func reveal(_ webView: XCUIElement, expand: XCUIElement, in transcript: XCUIElement) {
        for _ in 0..<Fixture.maximumScrolls {
            let viewport = transcript.frame.insetBy(dx: 0, dy: Fixture.viewportInset)
            let canvas = frame(of: webView).map { $0.union(expand.frame) }
            if let canvas, viewport.contains(canvas) { return }
            let adjustment = canvas.map { bounds in
                bounds.minY < viewport.minY ? viewport.minY - bounds.minY : viewport.maxY - bounds.maxY
            } ?? viewport.height * Fixture.dragNear
            let maximumStep = viewport.height * Fixture.dragNear
            let step = min(max(adjustment, -maximumStep), maximumStep)
            // Stay in the transcript's outer margin so the chart cannot consume this positioning drag.
            drag(
                transcript,
                from: CGVector(dx: Fixture.transcriptDragX, dy: 0.5),
                to: CGVector(dx: Fixture.transcriptDragX, dy: 0.5 + step / transcript.frame.height)
            )
        }
        XCTFail("The embedded diagram and fullscreen button could not be placed inside the transcript viewport")
    }

    @MainActor
    private func drag(_ element: XCUIElement, from start: CGVector, to end: CGVector) {
        element.coordinate(withNormalizedOffset: start).press(
            forDuration: Fixture.dragDuration,
            thenDragTo: element.coordinate(withNormalizedOffset: end),
            withVelocity: .slow,
            thenHoldForDuration: Fixture.dragHold
        )
    }

    @MainActor
    private func capture(_ app: XCUIApplication, name: String) {
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = name
        screenshot.lifetime = .keepAlways
        add(screenshot)
        let hierarchy = XCTAttachment(string: app.debugDescription)
        hierarchy.name = "\(name)-hierarchy"
        hierarchy.lifetime = .keepAlways
        add(hierarchy)
    }
}
