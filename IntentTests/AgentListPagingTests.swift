import Foundation
@testable import Intent
import Testing

/// `agent.list` against a bounded daemon (protocol "Paged agent lists and
/// queues"): rows ascend by `(createdAt, id)`, so the newest agents are on the
/// last page. Every caller reads every page of its variant, and a walk that
/// fails or cannot finish never publishes a partial list as whole.
@MainActor
struct AgentListPagingTests {
    private struct PageError: Error {}

    static func rows(_ range: ClosedRange<Int>, parent: String? = nil) -> [[String: Any]] {
        range.map { index in
            var row: [String: Any] = ["id": "agent-\(index)", "name": "Agent \(index)"]
            if let parent { row["parentAgentId"] = parent }
            return row
        }
    }

    static func page(_ rows: [[String: Any]], next: String?) -> [String: Any] {
        [
            "agents": rows, "retiredCount": 4,
            "scopeCounts": ["topLevel": 250, "delegated": 3, "background": 0],
            "delegatedCounts": ["running": 0, "byParent": ["agent-1": ["total": 3, "running": 0]]],
            "nextToken": next.map { $0 as Any } ?? NSNull()
        ]
    }

    private static func ids(_ reply: Any) -> [String] {
        let rows = ((reply as? [String: Any])?["agents"] as? [[String: Any]]) ?? []
        return rows.compactMap { $0["id"] as? String }
    }

    // MARK: - requestWholeReply

    @Test func wholeReplyJoinsEveryPageUnderTheFirstEnvelope() async throws {
        var sent: [[String: Any]] = []
        let replies = [
            Self.page(Self.rows(1...2), next: "t1"),
            Self.page(Self.rows(3...3), next: "t2"),
            // An empty last page still ends the walk cleanly.
            Self.page([], next: nil)
        ]
        let reply = try await PagedReads.requestWholeReply(params: ["workspaceId": "ws-1"], field: "agents") { params in
            sent.append(params)
            return replies[sent.count - 1]
        }
        let whole = try #require(reply as? [String: Any])
        #expect(Self.ids(whole) == ["agent-1", "agent-2", "agent-3"])
        #expect(whole["retiredCount"] as? Int == 4)
        #expect(whole["nextToken"] == nil)
        #expect(sent.map { $0["nextToken"] as? String } == [nil, "t1", "t2"])
        #expect(sent.allSatisfy { $0["workspaceId"] as? String == "ws-1" })
    }

    @Test func wholeReplyReturnsAnUnpagedReplyUnchanged() async throws {
        var calls = 0
        let reply = try await PagedReads.requestWholeReply(params: [:], field: "agents") { _ in
            calls += 1
            return ["agents": Self.rows(1...2), "retiredCount": 1] as [String: Any]
        }
        #expect(calls == 1)
        #expect(Self.ids(reply) == ["agent-1", "agent-2"])
        #expect((reply as? [String: Any])?["retiredCount"] as? Int == 1)
    }

    @Test func wholeReplyReturnsAMalformedFirstReplyUnchanged() async throws {
        var calls = 0
        let reply = try await PagedReads.requestWholeReply(params: [:], field: "queue") { _ in
            calls += 1
            return ["queue": "not-an-array", "nextToken": "t1"] as [String: Any]
        }
        #expect(calls == 1)
        #expect((reply as? [String: Any])?["queue"] as? String == "not-an-array")
        let bare = try await PagedReads.requestWholeReply(params: [:], field: "queue") { _ in "not-an-object" }
        #expect(bare as? String == "not-an-object")
    }

    @Test func wholeReplyFailsOnAMalformedContinuationPage() async {
        var calls = 0
        await #expect(throws: PagedReads.MalformedPage.self) {
            _ = try await PagedReads.requestWholeReply(params: [:], field: "agents") { _ in
                calls += 1
                return calls == 1 ? Self.page(Self.rows(1...1), next: "t1") : ["unexpected": true]
            }
        }
        #expect(calls == 2)
    }

    @Test func wholeReplyFailsOnAPageErrorMidWalk() async {
        var calls = 0
        await #expect(throws: PageError.self) {
            _ = try await PagedReads.requestWholeReply(params: [:], field: "agents") { _ in
                calls += 1
                if calls == 2 { throw PageError() }
                return Self.page(Self.rows(calls...calls), next: "t\(calls)")
            }
        }
        #expect(calls == 2)
    }

    @Test func wholeReplyFailsOnARepeatedToken() async {
        var calls = 0
        await #expect(throws: PagedReads.IncompleteWalk.self) {
            _ = try await PagedReads.requestWholeReply(params: [:], field: "agents") { _ in
                calls += 1
                return Self.page(Self.rows(calls...calls), next: "same")
            }
        }
        #expect(calls == 2)
    }

    @Test func wholeReplyFailsAtThePageLimit() async {
        var calls = 0
        await #expect(throws: PagedReads.IncompleteWalk.self) {
            _ = try await PagedReads.requestWholeReply(params: [:], field: "agents") { _ in
                calls += 1
                return Self.page([], next: "t\(calls)")
            }
        }
        #expect(calls == PagedReads.maxPages)
    }

    // MARK: - requestAgentList

    @Test func agentListRepeatsTheVariantOnEveryPage() async throws {
        let fake = FakeConnectionManager()
        fake.responseQueueMap["agent.list"] = [
            Self.page(Self.rows(1...200, parent: "p"), next: "t1"),
            Self.page(Self.rows(201...210, parent: "p"), next: nil)
        ]
        let reply = try await PagedReads.requestAgentList(
            ["workspaceId": "ws-1", "scope": "delegated", "parentAgentId": "p"], connection: fake
        )
        #expect(Self.ids(reply).count == 210)
        let sent = fake.paramsForMethod("agent.list")
        #expect(sent.map { $0["nextToken"] as? String } == [nil, "t1"])
        #expect(sent.allSatisfy { params in
            params["workspaceId"] as? String == "ws-1" && params["scope"] as? String == "delegated"
                && params["parentAgentId"] as? String == "p" && params["limit"] as? Int == PagedReads.agentPageLimit
        })
    }

    @Test func agentListStopsBeforeTheNextPageOnceStale() async {
        let fake = FakeConnectionManager()
        fake.responseQueueMap["agent.list"] = [Self.page(Self.rows(1...1), next: "t1")]
        await #expect(throws: CancellationError.self) {
            _ = try await PagedReads.requestAgentList(["workspaceId": "ws-1"], connection: fake) { false }
        }
        #expect(fake.paramsForMethod("agent.list").count == 1)
    }

    // MARK: - AgentStore

    @Test func agentStoreTopLevelReadPublishesEveryPage() async {
        let fake = FakeConnectionManager()
        let store = AgentStore(connectionManager: fake, scopedLoading: true)
        fake.responseQueueMap["agent.list"] = [
            Self.page(Self.rows(1...200), next: "t1"),
            Self.page(Self.rows(201...250), next: "t2"),
            Self.page([], next: nil)
        ]

        await store.fetchAgents(workspaceId: "ws-1")

        #expect(store.agents.count == 250)
        #expect(store.agents.contains { $0.id == "agent-250" }, "The newest agent is on the last page")
        #expect(store.list.retiredCount == 4)
        #expect(store.list.scopeCounts?.topLevel == 250)
        let sent = fake.paramsForMethod("agent.list")
        #expect(sent.map { $0["nextToken"] as? String } == [nil, "t1", "t2"])
        #expect(sent.allSatisfy { $0["scope"] as? String == "topLevel" && $0["limit"] as? Int == PagedReads.agentPageLimit })
    }

    @Test func agentStoreFailedPageKeepsThePreviousList() async {
        let fake = FakeConnectionManager()
        let store = AgentStore(connectionManager: fake, scopedLoading: true)
        fake.responseMap["agent.list"] = Self.page(Self.rows(1...3), next: nil)
        await store.fetchAgents(workspaceId: "ws-1")
        #expect(store.agents.count == 3)

        fake.responseMap["agent.list"] = nil
        fake.responseQueueMap["agent.list"] = [Self.page(Self.rows(1...1), next: "t1")]
        // The second page has no configured reply, so it fails.
        await store._fetchAgents(workspaceId: "ws-1")

        #expect(store.agents.map(\.id).sorted() == ["agent-1", "agent-2", "agent-3"])
        #expect(fake.paramsForMethod("agent.list").last?["nextToken"] as? String == "t1")
    }

    @Test func agentStoreRepeatedTokenKeepsThePreviousList() async {
        let fake = FakeConnectionManager()
        let store = AgentStore(connectionManager: fake, scopedLoading: true)
        fake.responseMap["agent.list"] = Self.page(Self.rows(1...3), next: nil)
        await store.fetchAgents(workspaceId: "ws-1")

        fake.responseMap["agent.list"] = Self.page(Self.rows(1...1), next: "same")
        await store._fetchAgents(workspaceId: "ws-1")

        #expect(store.agents.count == 3)
        #expect(store.hasLoaded)
    }

    @Test func agentStoreGroupReadWalksEveryPageOfItsVariant() async {
        let fake = FakeConnectionManager()
        let store = AgentStore(connectionManager: fake, scopedLoading: true)
        fake.responseMap["agent.list"] = Self.page(Self.rows(1...1), next: nil)
        await store.fetchAgents(workspaceId: "ws-1")
        fake.responseMap["agent.list"] = nil
        fake.responseQueueMap["agent.list"] = [
            Self.page(Self.rows(2...201, parent: "agent-1"), next: "t1"),
            Self.page(Self.rows(202...203, parent: "agent-1"), next: nil)
        ]

        await store.loadAgentGroup(.delegated(parentId: "agent-1"), workspaceId: "ws-1")

        #expect(store.list.loadedGroups.contains(.delegated(parentId: "agent-1")))
        #expect(store.agents.filter { $0.parentAgentId == "agent-1" }.count == 202)
        let sent = fake.paramsForMethod("agent.list").dropFirst()
        #expect(sent.map { $0["nextToken"] as? String } == [nil, "t1"])
        #expect(sent.allSatisfy { $0["scope"] as? String == "delegated" && $0["parentAgentId"] as? String == "agent-1" })
    }

    @Test func agentStoreGroupPageErrorLeavesTheSectionRetryable() async {
        let fake = FakeConnectionManager()
        let store = AgentStore(connectionManager: fake, scopedLoading: true)
        fake.responseMap["agent.list"] = Self.page(Self.rows(1...1), next: nil)
        await store.fetchAgents(workspaceId: "ws-1")
        fake.responseMap["agent.list"] = nil
        fake.responseQueueMap["agent.list"] = [Self.page(Self.rows(2...3, parent: "agent-1"), next: "t1")]

        await store.loadAgentGroup(.delegated(parentId: "agent-1"), workspaceId: "ws-1")

        #expect(!store.list.loadedGroups.contains(.delegated(parentId: "agent-1")))
        #expect(store.list.errors[.delegated(parentId: "agent-1")] != nil)
        #expect(!store.agents.contains { $0.parentAgentId == "agent-1" }, "A partial section is never published")
    }

    @Test func agentStoreSupersededWalkStopsBeforeItsNextPage() async throws {
        let fake = FakeConnectionManager()
        let store = AgentStore(connectionManager: fake, scopedLoading: true)
        fake.pendingMethods.insert("agent.list")
        let first = Task { await store.fetchAgents(workspaceId: "ws-1") }
        try await fake.waitForPendingRequests("agent.list")
        let second = Task { await store.fetchAgents(workspaceId: "ws-2") }
        try await fake.waitForPendingRequests("agent.list", count: 2)

        fake.resolvePending("agent.list", with: Self.page(Self.rows(1...1), next: "t1"))
        await first.value
        fake.resolvePending("agent.list", with: Self.page(Self.rows(5...6), next: nil))
        await second.value

        let sent = fake.paramsForMethod("agent.list")
        #expect(sent.count == 2, "The ws-1 walk must not read its next page after the switch")
        #expect(sent.allSatisfy { $0["nextToken"] == nil })
        #expect(store.agents.map(\.id).sorted() == ["agent-5", "agent-6"])
    }

    // MARK: - AssistantStore

    @Test func assistantThreadsComeFromEveryPage() async {
        let fake = FakeConnectionManager()
        fake.responseQueueMap["agent.list"] = [
            Self.page(Self.rows(1...200), next: "t1"),
            Self.page(Self.rows(201...201), next: nil)
        ]
        let store = AssistantStore(connection: fake)

        await store.refresh()

        #expect(store.threads.count == 201)
        #expect(store.threads.contains { $0.id == "agent-201" })
        #expect(fake.paramsForMethod("agent.list").allSatisfy { $0["workspaceId"] as? String == Workspace.chiefWorkspaceId })
    }

    @Test func assistantPageErrorKeepsThePreviousThreads() async {
        let fake = FakeConnectionManager()
        fake.responseMap["agent.list"] = Self.page(Self.rows(1...2), next: nil)
        let store = AssistantStore(connection: fake)
        await store.refresh()
        fake.responseMap["agent.list"] = nil
        fake.responseQueueMap["agent.list"] = [Self.page(Self.rows(3...3), next: "t1")]

        await store.refresh()

        #expect(store.threads.map(\.id).sorted() == ["agent-1", "agent-2"])
        #expect(store.errorMessage != nil)
    }
}
