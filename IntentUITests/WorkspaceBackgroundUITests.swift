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
    private func openWorkspace(in app: XCUIApplication, appearance: String) throws -> [Double] {
        app.launchArguments = ["--demo-data", "-appThemePreference", appearance]
        app.launch()
        let workspace = app.buttons["workspace.row.demo-ws-dashboard"]
        XCTAssertTrue(workspace.waitForExistence(timeout: Sample.timeout))
        workspace.tap()
        let heading = app.staticTexts["workspace.title.heading"]
        XCTAssertTrue(heading.waitForExistence(timeout: Sample.timeout))
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
        return (0..<3).map { channel in
            let values = stride(from: channel, to: bytes.count, by: Sample.bytesPerPixel).map { Double(bytes[$0]) }.sorted()
            return values[values.count / 2]
        }
    }
}
