import XCTest

private enum HomeActionMenuTestSupport {
    static let timeout: TimeInterval = 30
    static let maximumSwipes = 12
}

extension XCUIApplication {
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
            if viewport.contains(CGPoint(x: tile.frame.midX, y: tile.frame.midY)) { break }
            carousel.swipeLeft()
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
