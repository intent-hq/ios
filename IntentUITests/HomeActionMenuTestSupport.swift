import XCTest

extension XCUIElementQuery {
    @MainActor
    func waitForSingleHittableElement(timeout: TimeInterval, file: StaticString = #filePath, line: UInt = #line) throws -> XCUIElement {
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate { candidate, _ in
            guard let query = candidate as? XCUIElementQuery else { return false }
            return query.allElementsBoundByIndex.filter(\.isHittable).count == 1
        }, object: self)
        XCTAssertEqual(
            XCTWaiter.wait(for: [ready], timeout: timeout),
            .completed,
            "Exactly one retained control must become hittable",
            file: file,
            line: line
        )
        return try singleHittableElement(file: file, line: line)
    }

    @MainActor
    func singleHittableElement(file: StaticString = #filePath, line: UInt = #line) throws -> XCUIElement {
        let visible = allElementsBoundByIndex.filter(\.isHittable)
        XCTAssertEqual(visible.count, 1, "Exactly one retained control must accept input", file: file, line: line)
        return try XCTUnwrap(visible.first, file: file, line: line)
    }
}

private enum HomeActionMenuTestSupport {
    static let timeout: TimeInterval = 30
    static let maximumSwipes = 12
    static let dragHoldDuration: TimeInterval = 0.1
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
        var viewport = carousel.frame.intersection(frame)
        for _ in 0..<HomeActionMenuTestSupport.maximumSwipes {
            viewport = carousel.frame.intersection(frame)
            let target = tile.frame
            if viewport.contains(CGPoint(x: target.midX, y: target.midY)) { break }
            // A fling can skip a tile, and the next target may be behind us.
            // Drag toward its center, at most half a viewport, then remeasure.
            let limit = viewport.width / 2
            let distance = min(max(viewport.midX - target.midX, -limit), limit)
            let start = coordinate(withNormalizedOffset: .zero).withOffset(CGVector(
                dx: viewport.midX - frame.minX - distance / 2,
                dy: viewport.midY - frame.minY
            ))
            start.press(
                forDuration: HomeActionMenuTestSupport.dragHoldDuration,
                thenDragTo: start.withOffset(CGVector(dx: distance, dy: 0)),
                withVelocity: .slow,
                thenHoldForDuration: HomeActionMenuTestSupport.dragHoldDuration
            )
        }
        viewport = carousel.frame.intersection(frame)
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
