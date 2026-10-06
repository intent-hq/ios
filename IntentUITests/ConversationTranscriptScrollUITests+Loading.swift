import UIKit
import XCTest

extension ConversationTranscriptScrollUITests {
    // Exported artwork samples and screen-relative positions are intentional fixture data.
    // swiftlint:disable no_magic_numbers
    private enum BackgroundSample {
        static let bottom = CGPoint(x: 0.75, y: 0.99)
        static let colorTolerance = 4
        static let solidChannelTolerance = 8
        static let channelCount = 4
        static let colorChannelCount = 3
        static let bitsPerComponent = 8
        static let dark = [28, 28, 36]
        static let artwork: [(CGPoint, [Int])] = [
            (CGPoint(x: 0.75, y: 0.01), [243, 242, 241]),
            (CGPoint(x: 0.99, y: 0.10), [242, 240, 237]),
            (CGPoint(x: 0.99, y: 0.90), [232, 239, 139]),
            (bottom, [231, 244, 117])
        ]
    }
    // swiftlint:enable no_magic_numbers

    @MainActor
    func testLoadingGradientCoversChromeAndRestoresSolidBackground() throws {
        for appearance in ["light", "dark"] {
            try assertLoadingBackground(appearance: appearance)
        }
    }

    @MainActor
    private func assertLoadingBackground(appearance: String) throws {
        let app = try launchStartupConversation(metadataReady: true, holdSnapshot: true, appearance: appearance)
        defer { finishStartup(app) }
        let opened = enterLongConversation(in: app, context: "full-screen loading", waitForTranscript: false)
        XCTAssertTrue(startupControl(app).waitForExistence(timeout: Fixture.settleTimeout))
        XCTAssertFalse(opened.transcript.exists, "The snapshot must remain held while checking loading chrome")

        let loading = app.screenshot()
        attachBackground(loading, named: "Conversation loading full-screen \(appearance)")
        // Sample outside the controls, including the top and bottom safe areas.
        // These are the exported artwork colors at each screen-relative height.
        for (point, lightColor) in BackgroundSample.artwork {
            let expected = appearance == "light" ? lightColor : BackgroundSample.dark
            let actual = try backgroundPixel(loading, at: point)
            XCTAssertTrue(
                zip(actual, expected).allSatisfy { abs($0 - $1) <= BackgroundSample.colorTolerance },
                "Loading artwork must cover the chrome at \(point): got \(actual), expected \(expected)"
            )
        }

        try Data().write(to: startupSnapshotGate)
        XCTAssertTrue(opened.transcript.waitForExistence(timeout: Fixture.settleTimeout))
        XCTAssertTrue(waitUntil(timeout: Fixture.settleTimeout) { self.startupReport(app).contains("positioned=true") })
        let loaded = app.screenshot()
        attachBackground(loaded, named: "Conversation loaded solid background \(appearance)")
        let bottom = try backgroundPixel(loaded, at: BackgroundSample.bottom)
        XCTAssertLessThanOrEqual(abs(bottom[0] - bottom[2]), BackgroundSample.solidChannelTolerance, "The yellow loading artwork must leave after messages arrive")
    }

    private func attachBackground(_ screenshot: XCUIScreenshot, named name: String) {
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func backgroundPixel(_ screenshot: XCUIScreenshot, at point: CGPoint) throws -> [Int] {
        let image = try XCTUnwrap(screenshot.image.cgImage)
        let rect = CGRect(x: CGFloat(image.width - 1) * point.x, y: CGFloat(image.height - 1) * point.y, width: 1, height: 1)
        let sample = try XCTUnwrap(image.cropping(to: rect))
        let colorSpace = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        var bytes = [UInt8](repeating: 0, count: BackgroundSample.channelCount)
        try bytes.withUnsafeMutableBytes { buffer in
            let context = try XCTUnwrap(CGContext(
                data: buffer.baseAddress,
                width: 1,
                height: 1,
                bitsPerComponent: BackgroundSample.bitsPerComponent,
                bytesPerRow: BackgroundSample.channelCount,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
            ))
            context.draw(sample, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        return bytes.prefix(BackgroundSample.colorChannelCount).map(Int.init)
    }
}
