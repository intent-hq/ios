import Foundation
@testable import Intent
import Testing

/// Which tapped links iOS can't open, so the transcript shows a message
/// instead of silently dropping the tap.
struct UnopenableLinkTests {
    @Test(arguments: [
        "report.html",
        "./reports/report.html",
        "../report.html",
        "/Users/me/project/report.html",
        "#summary",
        "file:///Users/me/project/report.html",
        "FILE:///tmp/report.pdf",
        "workspace-asset://workspace/asset-1",
        "C:/Users/me/report.html"
    ])
    func pathsAndFileLinksAreUnopenable(_ address: String) throws {
        let url = try #require(URL(string: address))
        #expect(UnopenableLink.reason(for: url) == .unsupportedLocation)
    }

    @Test(arguments: [
        "intent://local/settings",
        "intent://local/workspace/demo",
        "intent://remote/file/notes.txt",
        "INTENT://local/browser"
    ])
    func unroutedIntentLinksAreUnopenable(_ address: String) throws {
        let url = try #require(URL(string: address))
        #expect(UnopenableLink.reason(for: url) == .unsupportedIntentLink)
    }

    @Test(arguments: [
        "https://example.com/report.html",
        "http://localhost:3000",
        "mailto:hello@example.com",
        "tel:+15555550100",
        "intent://pair?payload=abc"
    ])
    func linksIOSCanOpenKeepSystemRouting(_ address: String) throws {
        let url = try #require(URL(string: address))
        #expect(UnopenableLink.reason(for: url) == nil)
    }

    @Test func messageNamesTheLinkTarget() throws {
        let url = try #require(URL(string: "reports/report.html"))
        let link = UnopenableLink(url: url, reason: .unsupportedLocation)
        #expect(link.target == "reports/report.html")
        #expect(link.message == "This link can't be opened on this device.\n\nreports/report.html")
    }

    @Test func browserFailureExplainsTheError() throws {
        let url = try #require(URL(string: "http://user@localhost:3000"))
        let link = UnopenableLink(url: url, reason: .browserFailed("Bad address."))
        #expect(link.message == "The in-app browser couldn't open this link. Bad address.\n\nhttp://user@localhost:3000")
    }
}
