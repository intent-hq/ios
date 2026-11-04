import Foundation
@testable import Intent
import Testing

/// `script.list` full-view pages (protocol "Full-view pages", `boundedReads: 1`):
/// a bounded host answers 100 definitions per page with `nextCursor`, absent
/// on the last page; hosts without the capability reject `limit` / `cursor`
/// on the full view, so the first request carries neither.
@MainActor
struct ScriptListPagingTests {
    private struct PageError: Error {}

    private static func scripts(_ range: ClosedRange<Int>) -> [[String: Any]] {
        range.map { ["id": "script-\($0)", "workspaceId": "workspace", "name": "Script \($0)", "command": "make \($0)"] }
    }

    // MARK: - PagedReads.requestAllScripts

    @Test func followsNextCursorUntilItIsAbsent() async throws {
        var sent: [[String: Any]] = []
        let replies: [[String: Any]] = [
            ["scripts": Self.scripts(1...100), "nextCursor": "c1"],
            ["scripts": Self.scripts(101...200), "nextCursor": "c2"],
            ["scripts": [[String: Any]]()]
        ]
        let reply = try await PagedReads.requestAllScripts(workspaceId: "workspace") { params in
            sent.append(params)
            return replies[sent.count - 1]
        }
        let rows = try #require((reply as? [String: Any])?["scripts"] as? [[String: Any]])
        #expect(rows.count == 200)
        #expect((reply as? [String: Any])?["nextCursor"] == nil)
        #expect(sent.map { $0["cursor"] as? String } == [nil, "c1", "c2"])
        #expect(sent.allSatisfy { $0["workspaceId"] as? String == "workspace" && $0["limit"] == nil && $0["nextToken"] == nil })
    }

    @Test func anUnboundedHostIsReadOnceWithoutPagingParams() async throws {
        var sent: [[String: Any]] = []
        let reply = try await PagedReads.requestAllScripts(workspaceId: "workspace") { params in
            sent.append(params)
            return ["scripts": Self.scripts(1...3)]
        }
        #expect(((reply as? [String: Any])?["scripts"] as? [[String: Any]])?.count == 3)
        #expect(sent.count == 1)
        #expect(sent.first?.keys.sorted() == ["workspaceId"])
    }

    @Test func aPageErrorMidWalkFailsTheWholeRead() async {
        var calls = 0
        await #expect(throws: PageError.self) {
            _ = try await PagedReads.requestAllScripts(workspaceId: "workspace") { _ in
                calls += 1
                if calls == 2 { throw PageError() }
                return ["scripts": Self.scripts(1...100), "nextCursor": "c1"]
            }
        }
        #expect(calls == 2)
    }

    @Test func aRepeatedCursorFailsTheWholeRead() async {
        await #expect(throws: PagedReads.IncompleteWalk.self) {
            _ = try await PagedReads.requestAllScripts(workspaceId: "workspace") { _ in
                ["scripts": Self.scripts(1...1), "nextCursor": "same"]
            }
        }
    }

    // MARK: - Callers

    @Test func scriptStoreListsDefinitionsFromEveryPage() async {
        let fixture = WorkspaceScriptFixture()
        fixture.fake.responseQueueMap["script.list"] = [
            ["scripts": Self.scripts(1...100), "nextCursor": "c1"],
            ["scripts": Self.scripts(101...140)]
        ]
        await fixture.store.refresh(workspaceId: "workspace")
        #expect(fixture.store.scripts(workspaceId: "workspace").count == 140)
        #expect(fixture.store.errorMessage(workspaceId: "workspace") == nil)
    }

    @Test func scriptStorePageErrorKeepsThePreviousListAndShowsTheError() async {
        let fixture = WorkspaceScriptFixture()
        await fixture.load(Self.scripts(1...2))
        fixture.fake.pendingMethods = ["script.list"]
        let refresh = Task { await fixture.store.refresh(workspaceId: "workspace") }
        try? await fixture.fake.waitForPendingRequests("script.list")
        fixture.fake.resolvePending("script.list", with: ["scripts": Self.scripts(1...100), "nextCursor": "c1"] as [String: Any])
        try? await fixture.fake.waitForPendingRequests("script.list")
        fixture.fake.failPending("script.list", with: PageError())
        await refresh.value
        #expect(fixture.store.scripts(workspaceId: "workspace").count == 2)
        #expect(fixture.store.errorMessage(workspaceId: "workspace") != nil)
    }

    @Test func registrationReusesAScriptSavedOnALaterPage() async throws {
        let fixture = WorkspaceScriptFixture()
        fixture.fake.responseMap["file.list"] = [
            ["name": "package.json", "type": "file"], ["name": "pnpm-lock.yaml", "type": "file"]
        ]
        fixture.fake.responseMap["file.read"] = #"{"packageManager":"pnpm@10.30.3","scripts":{"dev":"astro dev"}}"#
        await fixture.load([fixture.definition(id: "verification")])
        let candidate = try #require(fixture.store.scripts(workspaceId: "workspace").first { $0.name == "dev" && !$0.isRegistered })
        let saved: [String: Any] = [
            "id": "registered-dev", "workspaceId": "workspace", "name": "dev", "command": candidate.command, "mode": candidate.mode
        ]
        // Later refreshes (after the launch) read the settled list.
        fixture.fake.responseMap["script.list"] = ["scripts": [fixture.definition(id: "verification"), saved]]
        fixture.fake.responseQueueMap["script.list"] = [
            ["scripts": Self.scripts(1...100), "nextCursor": "c1"],
            ["scripts": [saved]]
        ]
        fixture.fake.responseMap["script.status"] = fixture.runtime(status: "running", url: "localhost:4321")

        await fixture.store.launch(candidate)

        #expect(!fixture.fake.didCallMethod("script.create"))
        #expect(fixture.store.takeBrowserToOpen(workspaceId: "workspace")?.id == "script:registered-dev")
    }
}
