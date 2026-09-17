import Foundation
@testable import Intent
import Testing

/// Backend-supplied strings opened via `openURL` (context-mention chips,
/// PR-monitor chips) must go through the shared `ExternalLink` http/https
/// allowlist rather than a bare `URL(string:)` (ios#262). The call-site scan
/// reads the copies packaged into the test bundle (see TestBundleInputs),
/// never the checkout via `#filePath` (ios#320, ios#373).
struct ExternalLinkTests {
    /// Every view that hands a daemon-supplied string to `openURL`.
    private static let externalLinkCallSites = [
        "Intent/Views/Conversation/Content/ContextMentionChipView.swift",
        "Intent/Views/Conversation/Notices/PrMonitorWakeAttributionView.swift",
        "Intent/Views/Conversation/StatusStrip/MonitoredPrsRow.swift"
    ]

    // MARK: - Accepted: absolute http/https with a host

    @Test(arguments: [
        "https://github.com/octo/repo/pull/12",
        "http://example.com",
        "HTTPS://Example.com/Path?q=1#frag",
        "https://linear.app/i/AU-123",
        "  https://example.com/padded  \n"
    ])
    func acceptsAbsoluteHttpAndHttps(_ string: String) {
        let url = ExternalLink.url(from: string)
        #expect(url != nil, "expected \(string.debugDescription) to be accepted")
        #expect(url.map { ExternalLink.allowedSchemes.contains($0.scheme?.lowercased() ?? "") } == true)
        #expect(url?.host?.isEmpty == false)
    }

    @Test func acceptedUrlPreservesTheOriginalTarget() {
        let url = ExternalLink.url(from: "https://example.com/a/b?x=1#y")
        #expect(url?.absoluteString == "https://example.com/a/b?x=1#y")
    }

    // MARK: - Rejected: unsafe, non-web, or malformed

    @Test(arguments: [
        "javascript:alert(1)",
        "JavaScript:alert(1)",
        "file:///etc/passwd",
        "tel:+15555550100",
        "sms:+15555550100",
        "mailto:someone@example.com",
        "data:text/html,<script>alert(1)</script>",
        "ftp://example.com/file",
        "intent://local/note/spec",
        "myapp://open?token=abc",
        "x-apple.systempreferences:com.apple.preference"
    ])
    func rejectsNonHttpSchemes(_ string: String) {
        #expect(ExternalLink.url(from: string) == nil, "expected \(string.debugDescription) to be rejected")
    }

    @Test(arguments: [
        "",
        "   ",
        "not a url",
        "example.com/path",
        "//example.com/path",
        "/relative/path",
        "https://",
        "https:///path-without-host",
        "http:example.com",
        "https:/example.com",
        "://example.com"
    ])
    func rejectsSchemelessHostlessAndMalformedStrings(_ string: String) {
        #expect(ExternalLink.url(from: string) == nil, "expected \(string.debugDescription) to be rejected")
    }

    @Test func rejectsNil() {
        #expect(ExternalLink.url(from: nil) == nil)
    }

    // MARK: - Call sites route through the shared helper

    @Test func externalLinkCallSitesUseTheSharedAllowlist() throws {
        let inputs = try TestBundleInputs.current()
        for relativePath in Self.externalLinkCallSites {
            let url = try inputs.url(for: relativePath)
            let contents = try String(contentsOf: url, encoding: .utf8)
            #expect(
                contents.range(of: #"URL\s*\(\s*string\s*:"#, options: .regularExpression) == nil,
                "\(relativePath) builds a URL from a backend string without the allowlist"
            )
            #expect(
                contents.contains("ExternalLink.url("),
                "\(relativePath) does not route its openURL argument through ExternalLink"
            )
        }
    }
}
