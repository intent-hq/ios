import Foundation
@testable import Intent
import Testing

/// TaskStore against a bounded daemon (§6.9 "Paged snapshots"): the
/// `task.subscribe` seq-0 snapshot is the first page of task notes, and its
/// `nextToken` continues through the paged `task.list` (`WorkspaceTask` rows
/// plus `workspaceId`).
@MainActor
struct TaskStorePagingTests {
    private struct PageError: Error {}

    /// A snapshot row: a task note stamped with `specLinked`.
    private static func taskNote(_ id: String, title: String? = nil, status: String = "not_started") -> [String: Any] {
        [
            "id": id,
            "title": title ?? "Task \(id)",
            "status": status,
            "content": "Body of \(id)",
            "specLinked": true,
            "createdAt": "2026-11-01T00:00:00Z",
            "updatedAt": "2026-11-01T00:00:00Z"
        ]
    }

    /// A continuation row: the `task.list` projection plus `workspaceId`.
    private static func taskRow(_ id: String, title: String? = nil, status: String = "not_started") -> [String: Any] {
        [
            "id": id,
            "workspaceId": "ws-1",
            "title": title ?? "Task \(id)",
            "status": status,
            "specLinked": false,
            "updatedAt": "2026-11-01T00:00:00Z"
        ]
    }

    private static func taskNotes(_ range: ClosedRange<Int>) -> [[String: Any]] {
        range.map { taskNote("task-\($0)") }
    }

    private static func taskRows(_ range: ClosedRange<Int>) -> [[String: Any]] {
        range.map { taskRow("task-\($0)") }
    }

    /// Connected store with a `task.subscribe` handler registered as `sub-1`
    /// and the connect-time whole-list `task.list` read already settled.
    private func liveStore() async throws -> (TaskStore, FakeConnectionManager) {
        let fake = FakeConnectionManager()
        let store = TaskStore(workspaceId: "ws-1", connectionManager: fake)
        store.snapshotFiller.sleep = { _ in }
        fake.responseMap["task.list"] = ["tasks": [[String: Any]](), "stats": ["total": 0]]
        fake.responseMap["task.subscribe"] = ["subscriptionId": "sub-1"]
        fake.responseMap["task.unsubscribe"] = [:] as [String: Any]
        fake.simulateConnect()
        try await waitUntil("task.subscribe handler registration") { fake.hasSubscriptionHandler(id: "sub-1") }
        try await waitUntil("connect-time task.list") { fake.paramsForMethod("task.list").count == 1 }
        return (store, fake)
    }

    // MARK: - One-shot task.list

    @Test func fetchAllAsksForTheWholeList() async {
        let fake = FakeConnectionManager()
        let store = TaskStore(workspaceId: "ws-1", connectionManager: fake)
        fake.responseMap["task.list"] = ["tasks": Self.taskRows(1...3), "stats": ["total": 3]]

        await store.fetchAll()

        #expect(store.tasks.count == 3)
        let sent = fake.paramsForMethod("task.list")
        #expect(sent.count == 1)
        #expect(sent.first?["limit"] == nil && sent.first?["nextToken"] == nil)
    }

    @Test func fetchAllFollowsATokenToTheEmptyLastPage() async {
        let fake = FakeConnectionManager()
        let store = TaskStore(workspaceId: "ws-1", connectionManager: fake)
        fake.responseQueueMap["task.list"] = [
            ["tasks": Self.taskRows(1...200), "stats": ["total": 230], "nextToken": "t1"],
            ["tasks": Self.taskRows(201...230), "stats": ["total": 230], "nextToken": "t2"],
            ["tasks": [[String: Any]](), "stats": ["total": 230], "nextToken": NSNull()]
        ]

        await store.fetchAll()

        #expect(store.tasks.count == 230)
        let sent = fake.paramsForMethod("task.list")
        #expect(sent.map { $0["nextToken"] as? String } == [nil, "t1", "t2"])
        #expect(sent.allSatisfy { $0["workspaceId"] as? String == "ws-1" })
    }

    @Test func fetchAllFailingMidWalkKeepsThePreviousList() async {
        let fake = FakeConnectionManager()
        let store = TaskStore(workspaceId: "ws-1", connectionManager: fake)
        fake.responseMap["task.list"] = ["tasks": Self.taskRows(1...2)]
        await store.fetchAll()
        #expect(store.tasks.count == 2)

        fake.pendingMethods = ["task.list"]
        let fetch = Task { await store.fetchAll() }
        try? await fake.waitForPendingRequests("task.list")
        fake.resolvePending("task.list", with: ["tasks": Self.taskRows(1...200), "nextToken": "t1"] as [String: Any])
        try? await fake.waitForPendingRequests("task.list")
        fake.failPending("task.list", with: PageError())
        await fetch.value

        #expect(store.tasks.count == 2, "a partial list must not replace the whole one")
    }

    // MARK: - Paged task.subscribe snapshot

    @Test func pagedSnapshotPublishesOnceWholeWithDeltasOnTop() async throws {
        let (store, fake) = try await liveStore()
        fake.clearRequestLog()
        fake.pendingMethods = ["task.list"]

        fake.deliverSubscriptionPush(SubscriptionPush(
            subscriptionId: "sub-1", seq: 0, snapshot: Self.taskNotes(1...200), nextToken: "t1"
        ))
        try await fake.waitForPendingRequests("task.list")
        #expect(store.snapshotFiller.isFilling)
        #expect(store.tasks.isEmpty, "a partial snapshot must not replace the list")

        // A delta during the walk is newer than any later page row.
        fake.deliverSubscriptionPush(SubscriptionPush(
            subscriptionId: "sub-1",
            seq: 1,
            delta: .init(
                added: [],
                updated: [Self.taskNote("task-201", title: "From delta", status: "complete")],
                removedIds: ["task-202"]
            )
        ))
        #expect(store.tasks.isEmpty)

        fake.resolvePending("task.list", with: [
            "tasks": [Self.taskRow("task-201", title: "Stale page row"), Self.taskRow("task-202"), Self.taskRow("task-203")],
            "stats": ["total": 203],
            "nextToken": "t2"
        ] as [String: Any])
        try await fake.waitForPendingRequests("task.list")
        fake.resolvePending("task.list", with: [
            "tasks": [[String: Any]](), "stats": ["total": 203], "nextToken": NSNull()
        ] as [String: Any])

        try await waitUntil("whole snapshot published") { store.tasks.count == 202 }
        #expect(!store.snapshotFiller.isFilling)
        let fromDelta = store.tasks.first { $0.id == "task-201" }
        #expect(fromDelta?.title == "From delta")
        #expect(fromDelta?.status == "complete")
        #expect(!store.tasks.contains { $0.id == "task-202" })
        let sent = fake.paramsForMethod("task.list")
        #expect(sent.map { $0["nextToken"] as? String } == ["t1", "t2"])
        #expect(sent.allSatisfy { params in
            params["workspaceId"] as? String == "ws-1" && params["limit"] as? Int == PagedReads.taskPageLimit
        })

        // Deltas publish directly once the walk is over.
        fake.deliverSubscriptionPush(SubscriptionPush(
            subscriptionId: "sub-1", seq: 2, delta: .init(added: [Self.taskNote("task-999")], updated: [], removedIds: [])
        ))
        #expect(store.tasks.count == 203)
    }

    @Test func continuationRetriesAPageThatFailedMidWalk() async throws {
        let (store, fake) = try await liveStore()
        fake.errorQueueMap["task.list"] = [PageError()]
        fake.responseQueueMap["task.list"] = [
            ["tasks": Self.taskRows(201...300), "nextToken": "t2"],
            ["tasks": Self.taskRows(301...310), "nextToken": NSNull()]
        ]

        fake.deliverSubscriptionPush(SubscriptionPush(
            subscriptionId: "sub-1", seq: 0, snapshot: Self.taskNotes(1...200), nextToken: "t1"
        ))

        try await waitUntil("snapshot completed after retry") { store.tasks.count == 310 }
        #expect(store.snapshotFiller.failures == 0)
        let tokens = fake.paramsForMethod("task.list").dropFirst().map { $0["nextToken"] as? String }
        #expect(tokens == ["t1", "t1", "t2"])
    }

    @Test func continuationThatKeepsFailingShowsTheFirstPageAndResubscribes() async throws {
        let (store, fake) = try await liveStore()
        fake.clearRequestLog()
        fake.failsCancelledRequests = true
        fake.errorMap["task.list"] = PageError()

        fake.deliverSubscriptionPush(SubscriptionPush(
            subscriptionId: "sub-1", seq: 0, snapshot: Self.taskNotes(1...200), nextToken: "t1"
        ))

        // Three page attempts, then the resubscribe and its baseline `task.list`.
        try await waitUntil("resubscribed for a fresh snapshot") {
            fake.paramsForMethod("task.subscribe").count == 1 && fake.paramsForMethod("task.list").count == 4
        }
        try await waitUntil("live handler re-registered") { fake.hasSubscriptionHandler(id: "sub-1") }
        #expect(fake.paramsForMethod("task.unsubscribe").count == 1)
        #expect(store.tasks.count == 200, "the first page beats an empty list")
        #expect(store.snapshotFiller.failures == 1)

        fake.errorMap["task.list"] = nil
        fake.responseQueueMap["task.list"] = [["tasks": Self.taskRows(201...205), "nextToken": NSNull()]]
        fake.deliverSubscriptionPush(SubscriptionPush(
            subscriptionId: "sub-1", seq: 0, snapshot: Self.taskNotes(1...200), nextToken: "t9"
        ))
        try await waitUntil("recovered snapshot") { store.tasks.count == 205 }
        #expect(store.snapshotFiller.failures == 0)
    }

    @Test func unpagedSnapshotPublishesImmediately() async throws {
        let (store, fake) = try await liveStore()
        fake.clearRequestLog()
        fake.deliverSubscriptionPush(SubscriptionPush(subscriptionId: "sub-1", seq: 0, snapshot: Self.taskNotes(1...3)))
        #expect(store.tasks.count == 3)
        #expect(!store.snapshotFiller.isFilling)
        #expect(!fake.didCallMethod("task.list"))
    }
}
