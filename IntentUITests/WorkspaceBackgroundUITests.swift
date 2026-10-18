import XCTest

/// Guards the rendered page backgrounds in #833 without coupling to a SwiftUI token name.
nonisolated final class WorkspaceBackgroundUITests: XCTestCase {
    private enum Sample {
        static let timeout: TimeInterval = 30
        static let gutterInset: CGFloat = 8
        static let size: CGFloat = 4
        static let bytesPerPixel = 4
        static let bitsPerChannel = 8
        static let tolerance = 2.0
        static let darkChannel = 22.0
        static let lightChannel = 255.0
        static let lightSettings = [240.0, 240.0, 235.0]
        static let darkSidebar = [39.0, 39.0, 39.0]
        static let lightDiagnostics = [242.0, 242.0, 247.0]
        static let contentOffset: CGFloat = 40
    }

    @MainActor
    func testNoteBackgroundMatchesWorkspaceInBothAppearances() throws {
        for appearance in ["dark", "light"] {
            let app = XCUIApplication()
            let expected = try openWorkspace(in: app, appearance: appearance)
            app.buttons["Context"].firstMatch.tap()
            let note = app.buttons["workspace.note.demo-note-spec"]
            XCTAssertTrue(note.waitForExistence(timeout: Sample.timeout))
            note.tap()
            XCTAssertTrue(app.navigationBars["Spec"].waitForExistence(timeout: Sample.timeout))
            let goal = try app.staticTexts.matching(identifier: "Goal")
                .waitForSingleHittableElement(timeout: Sample.timeout)
            // The note's content padding leaves an empty gutter beside the Goal heading.
            let point = CGPoint(x: goal.frame.minX - Sample.gutterInset, y: goal.frame.midY)
            let actual = try background(in: app, at: point, capture: "workspace-background-note-\(appearance)")
            assertMatches(actual, expected: expected, screen: "Note (\(appearance))")
            app.terminate()
        }
    }

    @MainActor
    func testNewAgentBackgroundMatchesWorkspaceInBothAppearances() throws {
        for appearance in ["dark", "light"] {
            let app = XCUIApplication()
            let expected = try openWorkspace(in: app, appearance: appearance)
            app.buttons["Workspace actions"].tap()
            let createAgent = app.buttons["Create New Agent"]
            XCTAssertTrue(createAgent.waitForExistence(timeout: Sample.timeout))
            createAgent.tap()
            let navigation = app.navigationBars["New Agent"]
            XCTAssertTrue(navigation.waitForExistence(timeout: Sample.timeout))
            let specialist = app.staticTexts["Implementor"].firstMatch
            XCTAssertTrue(specialist.waitForExistence(timeout: Sample.timeout))
            specialist.tap()
            // Sample inside the sheet, outside the inset list cards and toolbar controls.
            var point = CGPoint(x: navigation.frame.minX + Sample.gutterInset, y: specialist.frame.midY)
            let actual = try background(in: app, at: point, capture: "workspace-background-agent-\(appearance)")
            assertMatches(actual, expected: expected, screen: "New Agent (\(appearance))")
            app.buttons["Next"].tap()
            let providerNavigation = app.navigationBars["Provider & Model"]
            XCTAssertTrue(providerNavigation.waitForExistence(timeout: Sample.timeout))
            let provider = app.buttons["creation.providerPicker"]
            XCTAssertTrue(provider.waitForExistence(timeout: Sample.timeout))
            point = CGPoint(x: providerNavigation.frame.minX + Sample.gutterInset, y: provider.frame.midY)
            let providerColor = try background(in: app, at: point, capture: "workspace-background-provider-\(appearance)")
            assertMatches(providerColor, expected: expected, screen: "Provider & Model (\(appearance))")
            app.terminate()
        }
    }

    @MainActor
    func testBrowserBackgroundMatchesWorkspaceInBothAppearances() throws {
        for appearance in ["dark", "light"] {
            let app = XCUIApplication()
            let expected = try openWorkspace(in: app, appearance: appearance, arguments: ["--demo-browsers"])
            let browser = app.buttons["browser.row.tab:demo-agent-browser"]
            for _ in 0..<3 where !browser.isHittable { app.swipeUp() }
            XCTAssertTrue(browser.waitForExistence(timeout: Sample.timeout))
            browser.tap()
            let navigation = app.navigationBars["Browser"]
            XCTAssertTrue(navigation.waitForExistence(timeout: Sample.timeout))
            let unavailable = app.staticTexts["Page unavailable"]
            XCTAssertTrue(unavailable.waitForExistence(timeout: Sample.timeout))
            // The demo has no live browser tunnel: sample native canvas, never web content.
            var point = CGPoint(x: navigation.frame.minX + Sample.gutterInset, y: unavailable.frame.midY)
            let canvas = try background(in: app, at: point, capture: "workspace-background-browser-\(appearance)")
            assertMatches(canvas, expected: expected, screen: "Browser (\(appearance))")
            let address = app.textFields["Browser URL"]
            XCTAssertTrue(address.waitForExistence(timeout: Sample.timeout))
            // The address control is inset; its outer gutter must match the page, not the card.
            point = CGPoint(x: navigation.frame.minX + Sample.gutterInset, y: address.frame.midY)
            let surround = try background(in: app, at: point, capture: "workspace-background-browser-address-\(appearance)")
            assertMatches(surround, expected: expected, screen: "Browser address surround (\(appearance))")
            app.terminate()
        }
    }

    @MainActor
    func testConversationBackgroundMatchesWorkspaceInBothAppearances() throws {
        for appearance in ["dark", "light"] {
            let app = XCUIApplication()
            let expected = try openWorkspace(in: app, appearance: appearance, arguments: ["--demo-browsers"])
            let agent = app.buttons["workspace.agent.demo-agent-implementor"]
            XCTAssertTrue(agent.waitForExistence(timeout: Sample.timeout))
            agent.tap()
            XCTAssertTrue(app.textViews["composer.textView"].waitForExistence(timeout: Sample.timeout))
            XCTAssertTrue(app.links["Open server preview"].firstMatch.waitForExistence(timeout: Sample.timeout))
            let transcript = app.scrollViews["transcript.scrollView"]
            XCTAssertTrue(transcript.waitForExistence(timeout: Sample.timeout))
            // This existing fixture has one short link, leaving the transcript center empty.
            let point = CGPoint(x: transcript.frame.midX, y: transcript.frame.midY)
            let actual = try background(in: app, at: point, capture: "workspace-background-conversation-\(appearance)")
            assertMatches(actual, expected: expected, screen: "Conversation (\(appearance))")
            app.terminate()
        }
    }

    @MainActor
    func testSettingsBackgroundsMatchWorkspaceInBothAppearances() throws {
        for appearance in ["dark", "light"] {
            let app = XCUIApplication()
            let reference = try openWorkspace(in: app, appearance: appearance, arguments: ["--demo-settings"])
            let expected = appearance == "dark" ? reference : Sample.lightSettings
            openSettings(in: app)
            let manual = app.buttons["settings.pairing.manual"]
            revealSettingsAction(manual, in: app)
            let settings = app.scrollViews["settings.scroll"]
            let point = CGPoint(x: settings.frame.minX + Sample.gutterInset, y: manual.frame.midY)
            let actual = try background(in: app, at: point, capture: "workspace-background-settings-\(appearance)")
            // The iPad sidebar keeps shell chrome; only the main panel uses the workspace background.
            let isSidebar = app.buttons["ipad.rail.settings"].exists
            let settingsExpected = isSidebar && appearance == "dark" ? Sample.darkSidebar : expected
            assertMatches(actual, expected: settingsExpected, screen: "Settings (\(appearance))")
            manual.tap()
            let host = app.textFields["manual.host"]
            XCTAssertTrue(host.waitForExistence(timeout: Sample.timeout))
            let cancel = app.buttons["ipad.pairing.cancel"]
            let close = cancel.exists ? cancel : app.buttons["connection-sheet.close"]
            // The close control shares the content inset; sample outside the field cards.
            let manualPoint = CGPoint(x: close.frame.minX - Sample.gutterInset, y: host.frame.midY)
            let manualColor = try background(in: app, at: manualPoint, capture: "workspace-background-manual-\(appearance)")
            assertMatches(manualColor, expected: expected, screen: "Manual connection (\(appearance))")
            close.tap()
            XCTAssertTrue(host.waitForNonExistence(timeout: Sample.timeout))
            // Pairing closes an overlay sidebar on smaller iPads; Cancel restores only the detail.
            if app.buttons["ipad.rail.settings"].exists { openSettings(in: app) }
            let disconnect = app.buttons["Disconnect"]
            revealSettingsAction(disconnect, in: app)
            disconnect.tap()
            let title = app.staticTexts["log-off.title"]
            XCTAssertTrue(title.waitForExistence(timeout: Sample.timeout))
            let cancelDisconnect = app.buttons["log-off.cancel"]
            let confirmationPoint = CGPoint(x: cancelDisconnect.frame.minX - Sample.gutterInset, y: title.frame.midY)
            let confirmation = try background(in: app, at: confirmationPoint, capture: "workspace-background-disconnect-confirmation-\(appearance)")
            assertMatches(confirmation, expected: expected, screen: "Disconnect confirmation (\(appearance))")
            cancelDisconnect.tap()
            app.terminate()
        }
    }

    @MainActor
    func testIPadSettingsSidebarKeepsShellBackgroundInBothLayouts() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad, "iPad sidebar")
        defer { XCUIDevice.shared.orientation = .portrait }
        // Landscape keeps the sidebar beside the workspace; portrait on smaller iPads opens it as a drawer.
        for (layout, orientation) in [("landscape", UIDeviceOrientation.landscapeLeft), ("portrait", .portrait)] {
            XCUIDevice.shared.orientation = orientation
            for appearance in ["dark", "light"] {
                let app = XCUIApplication()
                let content = try openWorkspace(
                    in: app,
                    appearance: appearance,
                    arguments: ["--demo-settings", "--demo-ipad-pane-geometry"]
                )
                let shell = appearance == "dark" ? Sample.darkSidebar : Sample.lightSettings
                openSettings(in: app)
                let manual = app.buttons["settings.pairing.manual"]
                let settings = app.scrollViews["settings.scroll"]
                let point = CGPoint(x: settings.frame.minX + Sample.gutterInset, y: manual.frame.midY)
                let sidebar = try background(in: app, at: point, capture: "ipad-settings-sidebar-\(layout)-\(appearance)")
                assertMatches(sidebar, expected: shell, screen: "iPad Settings sidebar (\(layout), \(appearance))")
                let heading = app.staticTexts["workspace.title.heading"]
                if heading.exists, heading.isHittable {
                    let detailPoint = CGPoint(x: heading.frame.minX - Sample.gutterInset, y: heading.frame.midY)
                    let detail = try background(in: app, at: detailPoint, capture: "ipad-settings-detail-\(layout)-\(appearance)")
                    assertMatches(detail, expected: content, screen: "iPad workspace beside Settings (\(layout), \(appearance))")
                }
                // A rounded corner would expose the drawer shade or a different shell color.
                let panel = app.descendants(matching: .any)["ipad.sidebar.panel.geometry"].firstMatch
                XCTAssertTrue(panel.waitForExistence(timeout: Sample.timeout))
                let corner = CGPoint(x: panel.frame.minX + 1, y: panel.frame.minY + 1)
                let cornerColor = try background(in: app, at: corner, capture: "ipad-settings-corner-\(layout)-\(appearance)")
                assertMatches(cornerColor, expected: shell, screen: "iPad Settings sidebar leading corner (\(layout), \(appearance))")
                app.terminate()
            }
        }
    }

    @MainActor
    func testSettingsSupportBackgroundsMatchWorkspaceInBothAppearances() throws {
        for appearance in ["dark", "light"] {
            let app = XCUIApplication()
            let expected = try openWorkspace(in: app, appearance: appearance, arguments: ["--demo-settings"])
            openSettings(in: app)
            let acknowledgements = app.buttons["Acknowledgements"]
            revealSettingsAction(acknowledgements, in: app)
            acknowledgements.tap()
            let navigation = app.navigationBars["Acknowledgements"]
            XCTAssertTrue(navigation.waitForExistence(timeout: Sample.timeout))
            let point = CGPoint(x: navigation.frame.minX + Sample.gutterInset, y: navigation.frame.maxY + Sample.contentOffset)
            let actual = try background(in: app, at: point, capture: "workspace-background-acknowledgements-\(appearance)")
            assertMatches(actual, expected: expected, screen: "Acknowledgements (\(appearance))")
            navigation.buttons.firstMatch.tap()
            XCTAssertTrue(navigation.waitForNonExistence(timeout: Sample.timeout))
            let logs = app.buttons["Export logs"]
            revealSettingsAction(logs, in: app)
            logs.tap()
            let exportNavigation = app.navigationBars["Export logs"]
            XCTAssertTrue(exportNavigation.waitForExistence(timeout: Sample.timeout))
            let share = app.buttons["diagnosticShareZIP"]
            XCTAssertTrue(share.waitForExistence(timeout: Sample.timeout))
            let exportPoint = CGPoint(x: exportNavigation.frame.minX + Sample.gutterInset, y: share.frame.midY)
            let diagnostics = try background(in: app, at: exportPoint, capture: "workspace-background-diagnostics-\(appearance)")
            let diagnosticsExpected = appearance == "dark" ? expected : Sample.lightDiagnostics
            assertMatches(diagnostics, expected: diagnosticsExpected, screen: "Export logs (\(appearance))")
            app.terminate()
        }
    }

    @MainActor
    private func openSettings(in app: XCUIApplication) {
        let rail = app.buttons["ipad.rail.settings"]
        if rail.exists {
            rail.tap()
        } else {
            if !app.buttons["intent.menu.open"].exists {
                app.buttons["workspaceDetail.back"].tap()
            }
            app.openHomeAction("settings")
        }
        XCTAssertTrue(app.scrollViews["settings.scroll"].wait(for: \.isHittable, toEqual: true, timeout: Sample.timeout))
    }

    @MainActor
    private func revealSettingsAction(_ element: XCUIElement, in app: XCUIApplication) {
        let scroll = app.scrollViews["settings.scroll"]
        for _ in 0..<3 where !element.isHittable || !scroll.frame.contains(element.frame) { scroll.swipeUp() }
        XCTAssertTrue(element.isHittable)
    }

    @MainActor
    private func openWorkspace(in app: XCUIApplication, appearance: String, arguments: [String] = []) throws -> [Double] {
        continueAfterFailure = false
        app.launchArguments = ["--demo-data", "-appThemePreference", appearance] + arguments
        app.launch()
        let workspace = app.buttons["workspace.row.demo-ws-dashboard"]
        XCTAssertTrue(workspace.waitForExistence(timeout: Sample.timeout))
        // Fresh simulators show a system alert that dims screenshots and blocks navigation.
        let allowNotifications = XCUIApplication(bundleIdentifier: "com.apple.springboard").alerts.buttons["Allow"]
        if allowNotifications.waitForExistence(timeout: 2) {
            allowNotifications.tap()
            XCTAssertTrue(allowNotifications.waitForNonExistence(timeout: Sample.timeout))
        }
        // Narrow iPads start with the sidebar collapsed, unlike a wide iPad.
        let workspaces = app.buttons["ipad.rail.workspaces"]
        if workspaces.exists { workspaces.tap() }
        XCTAssertTrue(workspace.wait(for: \.isHittable, toEqual: true, timeout: Sample.timeout))
        workspace.tap()
        let heading = app.staticTexts["workspace.title.heading"]
        XCTAssertTrue(heading.wait(for: \.label, toEqual: "Add usage analytics dashboard", timeout: Sample.timeout))
        let point = CGPoint(x: heading.frame.minX - Sample.gutterInset, y: heading.frame.midY)
        let reference = try background(in: app, at: point, capture: "workspace-background-reference-\(appearance)")
        let channel = appearance == "dark" ? Sample.darkChannel : Sample.lightChannel
        assertMatches(reference, expected: [channel, channel, channel], screen: "Workspace (\(appearance))")
        return reference
    }

    private func assertMatches(_ actual: [Double], expected: [Double], screen: String) {
        let difference = zip(actual, expected).map { abs($0 - $1) }.max() ?? .infinity
        XCTAssertLessThanOrEqual(difference, Sample.tolerance, "\(screen) RGB \(actual) must match workspace RGB \(expected)")
    }

    @MainActor
    private func background(in app: XCUIApplication, at point: CGPoint, capture: String) throws -> [Double] {
        let screenshot = app.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = capture
        attachment.lifetime = .keepAlways
        add(attachment)
        let image = try XCTUnwrap(screenshot.image.cgImage)
        let scale = CGFloat(image.width) / app.frame.width
        let region = CGRect(
            x: point.x - app.frame.minX,
            y: point.y - app.frame.minY,
            width: Sample.size,
            height: Sample.size
        ).applying(CGAffineTransform(scaleX: scale, y: scale)).integral
        let crop = try XCTUnwrap(image.cropping(to: region))
        var bytes = [UInt8](repeating: 0, count: crop.width * crop.height * Sample.bytesPerPixel)
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try XCTUnwrap(CGContext(
            data: &bytes,
            width: crop.width,
            height: crop.height,
            bitsPerComponent: Sample.bitsPerChannel,
            bytesPerRow: crop.width * Sample.bytesPerPixel,
            space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.draw(crop, in: CGRect(x: 0, y: 0, width: crop.width, height: crop.height))
        let channels = (0..<3).map { channel in
            let values = stride(from: channel, to: bytes.count, by: Sample.bytesPerPixel).map { Double(bytes[$0]) }.sorted()
            return values[values.count / 2]
        }
        print("Background sample \(capture): RGB \(channels) at \(point)")
        return channels
    }
}
