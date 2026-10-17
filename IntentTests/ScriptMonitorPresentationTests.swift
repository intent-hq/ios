import Foundation
@testable import Intent
import Testing

@MainActor
struct ScriptMonitorPresentationTests {
    private let now = Date(timeIntervalSince1970: 0)

    func summary(
        owner: String = "owner",
        workspace: String = "workspace",
        state: String = "active",
        preview: String? = nil,
        truncated: Bool? = nil // swiftlint:disable:this discouraged_optional_boolean
    ) -> ScriptMonitorSummary {
        ScriptMonitorSummary(
            monitorId: "watch",
            workspaceId: workspace,
            agentId: owner,
            scriptId: "script",
            runId: "watched-run",
            scriptName: "Long script name 日本語",
            mode: .service,
            state: state,
            createdAt: "2026-10-16T23:00:00Z",
            expiresAt: "2026-10-17T01:00:00Z",
            lineCount: nil,
            outputPatternPreview: preview,
            outputPatternTruncated: truncated
        )
    }

    @Test func ownershipAndActiveStateAreExact() {
        let owned = summary()
        let rows = [owned, summary(owner: "other"), summary(workspace: "other"), summary(state: "completed")]
        #expect(ScriptMonitorPresentation.ownedActive(rows, workspaceId: "workspace", agentId: "owner") == [owned])
        #expect(ScriptMonitorPresentation.ownedActive([summary(owner: "é")], workspaceId: "workspace", agentId: "e\u{301}").isEmpty)
    }

    @Test func emptyOwnerStillShowsPagingLoadingAndErrors() {
        #expect(showsStatus(cursor: "opaque"))
        #expect(showsStatus(loading: true))
        #expect(showsStatus(stale: true))
        #expect(showsStatus(error: "Unavailable"))
        #expect(!showsStatus())
    }

    @Test func deadlineDoesNotDeclareScriptCompletion() throws {
        let deadline = try #require(ISO8601DateFormatter.lenientDate(from: summary().expiresAt))
        #expect(ScriptMonitorPresentation.expiry(summary().expiresAt, now: deadline.addingTimeInterval(-1)) == "Watch expires in 1s")
        #expect(ScriptMonitorPresentation.expiry(summary().expiresAt, now: deadline) == ScriptMonitorPresentation.deadlineReached)
        #expect(ScriptMonitorPresentation.expiry(summary().expiresAt, now: deadline.addingTimeInterval(1)) == ScriptMonitorPresentation.deadlineReached)
        #expect(ScriptMonitorPresentation.ownedActive([summary()], workspaceId: "workspace", agentId: "owner").count == 1)
        #expect(ScriptMonitorPresentation.expiry("invalid", now: now) == "Expiry unavailable")
        #expect(ScriptMonitorPresentation.absoluteDate("invalid") == nil)
    }

    @Test func absoluteTimeUsesRequestedTimeZone() throws {
        let utc = try #require(TimeZone(secondsFromGMT: 0))
        let other = try #require(TimeZone(secondsFromGMT: 3600))
        let locale = Locale(identifier: "en_US_POSIX")
        let first = ScriptMonitorPresentation.absoluteDate(summary().expiresAt, locale: locale, timeZone: utc)
        let second = ScriptMonitorPresentation.absoluteDate(summary().expiresAt, locale: locale, timeZone: other)
        #expect(first != nil)
        #expect(first != second)
    }

    @Test func previewIsNeverPresentedAsFullConfiguration() throws {
        let monitor = summary(preview: "^build…", truncated: true)
        let preview = try #require(ScriptMonitorPresentation.pattern(summary: monitor, detail: nil))
        #expect(preview.label.contains("preview"))
        #expect(preview.value == "^build…")
        let pattern = "^build [0-9]+$\\n日本語"
        let detail = ScriptMonitorDetail(summary: monitor, outputPattern: pattern)
        let full = try #require(ScriptMonitorPresentation.pattern(summary: monitor, detail: detail))
        #expect(full.value == pattern)
        #expect(!full.label.contains("preview"))
        #expect(ScriptMonitorPresentation.pattern(summary: monitor, detail: .init(summary: monitor, outputPattern: nil)) == nil)
    }

    @Test func ownerFallbackAndIndependentLineTrigger() {
        #expect(ScriptMonitorPresentation.ownerName(nil, agentId: "owner") == "owner")
        #expect(ScriptMonitorPresentation.ownerName("  ", agentId: "owner") == "owner")
        #expect(ScriptMonitorPresentation.ownerName("Build agent", agentId: "owner") == "Build agent")
        #expect(ScriptMonitorPresentation.lineTrigger(1) == "Also notifies after 1 new output line.")
        #expect(ScriptMonitorPresentation.lineTrigger(25) == "Also notifies after 25 new output lines.")
        #expect(ScriptMonitorPresentation.notificationExplanation == "Notifies the agent when this run finishes or the watch expires.")
    }

    private func showsStatus(
        loading: Bool = false,
        stale: Bool = false,
        error: String? = nil,
        cursor: String? = nil
    ) -> Bool {
        ScriptMonitorPresentation.showsStatus(
            hasMonitors: false,
            isLoading: loading,
            isStale: stale,
            error: error,
            nextCursor: cursor
        )
    }
}
