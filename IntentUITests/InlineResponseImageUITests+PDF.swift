import XCTest

extension InlineResponseImageUITests {
    func assertPDFShareKeepsOriginalName(in app: XCUIApplication, timeout: TimeInterval) {
        let activity = app.otherElements["ActivityListView"].firstMatch
        let named = activity.descendants(matching: .any).matching(
            NSPredicate(format: "label CONTAINS %@", "Demo brief")
        ).firstMatch
        XCTAssertTrue(named.appears(timeout: timeout), "Share sheet must show the original PDF name")
        let cacheNamed = activity.descendants(matching: .any).matching(
            NSPredicate(format: "label CONTAINS %@", "chat-pdf-")
        ).firstMatch
        XCTAssertFalse(cacheNamed.exists, "Share sheet must not expose the cache filename")
    }
}
