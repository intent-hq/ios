import XCTest

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
    }

    @MainActor
    func testIPadSettingsSidebarKeepsShellBackground() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad, "iPad sidebar")
        XCUIDevice.shared.orientation = .portrait
        for appearance in ["dark", "light"] {
            let app = XCUIApplication.intent()
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
            let sidebar = try background(in: app, at: point, capture: "ipad-settings-sidebar-\(appearance)")
            assertMatches(sidebar, expected: shell, screen: "iPad Settings sidebar (\(appearance))")
            let heading = app.staticTexts["workspace.title.heading"]
            if heading.exists, heading.isHittable {
                let detailPoint = CGPoint(x: heading.frame.minX - Sample.gutterInset, y: heading.frame.midY)
                let detail = try background(in: app, at: detailPoint, capture: "ipad-settings-detail-\(appearance)")
                assertMatches(detail, expected: content, screen: "iPad workspace beside Settings (\(appearance))")
            }
            let panel = app.descendants(matching: .any)["ipad.sidebar.panel.geometry"].firstMatch
            XCTAssertTrue(panel.appears(timeout: Sample.timeout))
            let corner = CGPoint(x: panel.frame.minX + 1, y: panel.frame.minY + 1)
            let cornerColor = try background(in: app, at: corner, capture: "ipad-settings-corner-\(appearance)")
            assertMatches(cornerColor, expected: shell, screen: "iPad Settings sidebar leading corner (\(appearance))")
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
    private func openWorkspace(in app: XCUIApplication, appearance: String, arguments: [String] = []) throws -> [Double] {
        continueAfterFailure = false
        app.launchArguments = ["--demo-data", "-appThemePreference", appearance] + arguments
        app.launch()
        let workspace = app.buttons["workspace.row.demo-ws-dashboard"]
        XCTAssertTrue(workspace.appears(timeout: Sample.timeout))
        let allowNotifications = XCUIApplication(bundleIdentifier: "com.apple.springboard").alerts.buttons["Allow"]
        if allowNotifications.appears(timeout: 2) {
            allowNotifications.tap()
            XCTAssertTrue(allowNotifications.disappears(timeout: Sample.timeout))
        }
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
