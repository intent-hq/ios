import Foundation
@testable import Intent
import Testing

struct WorkspaceBrowserTests {
    @Test func browserRoundTripsThroughCodable() throws {
        let browser = WorkspaceBrowser(
            id: "browser:one", workspaceId: "workspace", title: "Preview",
            url: "http://127.0.0.1:3000", command: nil
        )
        let encoded = try JSONEncoder().encode(browser)
        #expect(try JSONDecoder().decode(WorkspaceBrowser.self, from: encoded) == browser)
    }

    @Test(arguments: [
        ("localhost:3000", "http://127.0.0.1:3000"),
        ("http://daemon.localhost:3000/path?theme=dark#top", "http://127.0.0.1:3000/path?theme=dark#top"),
        ("http://0.0.0.0:8080", "http://127.0.0.1:8080"),
        ("http://[::]:8080", "http://127.0.0.1:8080"),
        ("http://[::1]:8080", "http://127.0.0.1:8080"),
        ("  HTTPS://EXAMPLE.COM/path?x=1&y=2  ", "https://example.com/path?x=1&y=2"),
        ("example.com:8080/path", "http://example.com:8080/path"),
        ("localhost:3000/?next=https://example.com", "http://127.0.0.1:3000/?next=https://example.com")
    ])
    func normalizesWebAddresses(input: String, expected: String) throws {
        #expect(try WorkspaceBrowserURL.normalize(input) == expected)
    }

    @Test(arguments: [
        "", "  ", "hello world", "/relative/path", "//example.com",
        "file:///tmp/page.html", "ftp://example.com", "javascript:alert(1)", "data:text/html,hi",
        "http://", "https:///path", "http://example.com:0", "http://example.com:65536",
        "localhost:not-a-port", "http://example.com:", "http://example.com/%",
        "http://user:secret@localhost:3000", "http://user@localhost:3000", "http://@localhost:3000",
        "http://localhost:3000/\nheader", "http://localhost\\@example.com"
    ])
    func rejectsInvalidOrNonWebAddresses(input: String) {
        #expect(throws: WorkspaceBrowserError.self) { try WorkspaceBrowserURL.normalize(input) }
    }

    @Test func decodingRequiresARunningScriptInTheRequestedWorkspace() throws {
        let script: [String: Any] = [
            "id": "preview", "workspaceId": "workspace", "name": "Web preview", "command": "npm run dev",
            "runtime": ["status": "running", "detectedUrl": "http://localhost:3000/docs", "restartCount": 0]
        ]
        let browser = try #require(WorkspaceBrowser.detected(script: script, workspaceId: "workspace"))
        #expect(browser.id == "script:preview")
        #expect(browser.title == "Web preview")
        #expect(browser.command == "npm run dev")
        #expect(browser.url == "http://127.0.0.1:3000/docs")
        #expect(WorkspaceBrowser.detected(script: script, workspaceId: "other") == nil)
        for status in ["idle", "starting", "restarting", "exited"] {
            var stopped = script
            stopped["runtime"] = ["status": status, "detectedUrl": "http://localhost:3000"]
            #expect(WorkspaceBrowser.detected(script: stopped, workspaceId: "workspace") == nil)
        }
        for field in ["id", "workspaceId", "runtime", "command"] {
            var malformed = script
            malformed.removeValue(forKey: field)
            #expect(WorkspaceBrowser.detected(script: malformed, workspaceId: "workspace") == nil)
        }
    }

    @Test(arguments: ["", "javascript:alert(1)", "file:///tmp/page", "http://user:secret@localhost:3000"])
    func doesNotDiscoverInvalidURLs(url: String) {
        let script: [String: Any] = [
            "id": "preview", "workspaceId": "workspace", "name": "Preview", "command": "npm start",
            "runtime": ["status": "running", "detectedUrl": url]
        ]
        #expect(WorkspaceBrowser.detected(script: script, workspaceId: "workspace") == nil)
    }
}
