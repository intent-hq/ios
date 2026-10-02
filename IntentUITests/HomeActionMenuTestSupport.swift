import XCTest

private enum HomeActionMenuTestSupport {
    static let timeout: TimeInterval = 30
    static let maximumSwipes = 12
    static let bytesPerPixel = 4
    static let bitsPerChannel = 8
    static let channelMaximum = 255.0
}

extension XCUIApplication {
    @MainActor
    func renderedHomeActionIsDark(_ action: String) throws -> Bool {
        let tile = buttons["intent.menu.\(action)"]
        let image = try XCTUnwrap(screenshot().image.cgImage)
        let scale = CGFloat(image.width) / frame.width
        // The tile center is empty background between the icon and label.
        let region = CGRect(
            x: (tile.frame.midX - frame.minX) * scale,
            y: (tile.frame.midY - frame.minY) * scale,
            width: 1,
            height: 1
        )
        let pixel = try XCTUnwrap(image.cropping(to: region))
        var bytes = [UInt8](repeating: 0, count: HomeActionMenuTestSupport.bytesPerPixel)
        let context = try XCTUnwrap(CGContext(
            data: &bytes,
            width: 1,
            height: 1,
            bitsPerComponent: HomeActionMenuTestSupport.bitsPerChannel,
            bytesPerRow: HomeActionMenuTestSupport.bytesPerPixel,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.draw(pixel, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return Double(bytes[0]) / HomeActionMenuTestSupport.channelMaximum < 0.5
    }

    @MainActor
    func openHomeAction(_ action: String, file: StaticString = #filePath, line: UInt = #line) {
        let launcher = buttons["intent.menu.open"]
        XCTAssertTrue(launcher.waitForExistence(timeout: HomeActionMenuTestSupport.timeout), file: file, line: line)
        launcher.tap()
        revealHomeAction(action, file: file, line: line).tap()
    }

    @MainActor
    func revealHomeAction(_ action: String, file: StaticString = #filePath, line: UInt = #line) -> XCUIElement {
        let tile = buttons["intent.menu.\(action)"]
        let carousel = scrollViews["intent.menu.tiles"]
        XCTAssertTrue(tile.waitForExistence(timeout: HomeActionMenuTestSupport.timeout), file: file, line: line)
        let viewport = carousel.frame.intersection(frame)
        for _ in 0..<HomeActionMenuTestSupport.maximumSwipes {
            let tileCenter = CGPoint(x: tile.frame.midX, y: tile.frame.midY)
            if viewport.contains(tileCenter) { break }
            if tileCenter.x < viewport.minX {
                carousel.swipeRight()
            } else {
                carousel.swipeLeft()
            }
        }
        XCTAssertTrue(
            viewport.contains(CGPoint(x: tile.frame.midX, y: tile.frame.midY)),
            "Horizontal swipes must bring \(action) into view: tile \(tile.frame), viewport \(viewport)",
            file: file,
            line: line
        )
        XCTAssertTrue(tile.isHittable, file: file, line: line)
        return tile
    }
}
