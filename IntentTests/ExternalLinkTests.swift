import Foundation
import Testing
@testable import Intent

/// Backend-supplied strings opened via `openURL` (context-mention chips,
/// PR-monitor chips) must go through the shared `ExternalLink` http/https
/// allowlist rather than a bare `URL(string:)` (ios#262).
struct ExternalLinkTests {

    private static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // IntentTests/
        .deletingLastPathComponent()  // repo root

    /// Every view that hands a daemon-supplied string to `openURL`.
    private static let externalLinkCallSites = [
        "Intent/Views/Conversation/Content/ContextMentionChipView.swift",
        "Intent/Views/Conversation/Notices/PrMonitorWakeAttributionView.swift",
        "Intent/Views/Conversation/StatusStrip/MonitoredPrsRow.swift",
    ]

    // MARK: - Call sites route through the shared helper

    @Test func externalLinkCallSitesUseTheSharedAllowlist() throws {
        for relativePath in Self.externalLinkCallSites {
            let url = Self.repoRoot.appendingPathComponent(relativePath)
            let contents = try String(contentsOf: url, encoding: .utf8)
            #expect(
                contents.range(of: #"URL\s*\(\s*string\s*:"#, options: .regularExpression) == nil,
                "\(relativePath) builds a URL from a backend string without the allowlist")
            #expect(
                contents.contains("ExternalLink.url("),
                "\(relativePath) does not route its openURL argument through ExternalLink")
        }
    }
}
