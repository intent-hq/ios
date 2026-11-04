import Foundation
@testable import Intent
import Testing

/// CommentStore against a bounded daemon: the `comment.subscribe` snapshot is
/// the first `comment.list` page and the rest is read with its `nextToken`
/// (PROTOCOL §5.2 "Bounded note and comment reads", §6.9 "Paged snapshots").
@MainActor
struct CommentStorePagingTests {
    private struct PageError: Error {}

    private static func thread(_ id: String, count: Int = 1, truncated: Bool = false) -> [String: Any] {
        var row: [String: Any] = [
            "threadId": id,
            "noteId": "note-1",
            "status": "open",
            "createdAt": "2026-11-01T00:00:00Z",
            "lastActivity": "2026-11-01T00:00:00Z",
            "latestCommentAuthor": "Ada",
            "latestCommentAuthorType": "human",
            "latestCommentAt": "2026-11-01T00:00:00Z",
            "commentCount": count,
            "comments": [[String: Any]]()
        ]
        if truncated { row["commentsTruncated"] = true }
        return row
    }

    private static func threads(_ range: ClosedRange<Int>) -> [[String: Any]] {
        range.map { thread("thread-\($0)") }
    }

    private func liveStore() async throws -> (CommentStore, FakeConnectionManager) {
        let fake = FakeConnectionManager()
        let store = CommentStore(connectionManager: fake)
        store.snapshotFiller.sleep = { _ in }
        fake.responseMap["comment.subscribe"] = ["subscriptionId": "sub-1"]
        fake.responseMap["comment.unsubscribe"] = [:] as [String: Any]
        fake.simulateConnect()
        await store.subscribeToNote(workspaceId: "ws-1", noteId: "note-1")
        // The connect observer resubscribes from its own task; let it settle.
        try await fake.waitForRequests("comment.subscribe", count: 2)
        try await waitUntil("comment.subscribe handler registration") { fake.hasSubscriptionHandler(id: "sub-1") }
        fake.clearRequestLog()
        return (store, fake)
    }

    @Test func subscribeAsksForTheMaximumPage() async {
        let fake = FakeConnectionManager()
        let store = CommentStore(connectionManager: fake)
        fake.responseMap["comment.subscribe"] = ["subscriptionId": "sub-1"]
        await store.subscribeToNote(workspaceId: "ws-1", noteId: "note-1")
        #expect(fake.paramsForMethod("comment.subscribe").first?["limit"] as? Int == PagedReads.commentPageLimit)
    }

    @Test func pagedSnapshotShowsEveryThread() async throws {
        let (store, fake) = try await liveStore()
        fake.responseQueueMap["comment.list"] = [
            ["threads": Self.threads(101...200), "nextToken": "t2"],
            ["threads": Self.threads(201...230), "nextToken": NSNull()]
        ]

        fake.deliverSubscriptionPush(SubscriptionPush(
            subscriptionId: "sub-1", seq: 0, snapshot: Self.threads(1...100), nextToken: "t1"
        ))

        try await waitUntil("every thread loaded") { store.threads.count == 230 }
        let sent = fake.paramsForMethod("comment.list")
        #expect(sent.map { $0["nextToken"] as? String } == ["t1", "t2"])
        #expect(sent.allSatisfy { params in
            params["workspaceId"] as? String == "ws-1" && params["noteId"] as? String == "note-1"
                && params["includeComments"] as? Bool == true && params["limit"] as? Int == PagedReads.commentPageLimit
        })
        #expect(!fake.didCallMethod("comment.getThread"))
    }

    @Test func continuationRetriesAPageThatFailedMidWalk() async throws {
        let (store, fake) = try await liveStore()
        fake.pendingMethods = ["comment.list"]

        fake.deliverSubscriptionPush(SubscriptionPush(
            subscriptionId: "sub-1", seq: 0, snapshot: Self.threads(1...100), nextToken: "t1"
        ))
        try await fake.waitForPendingRequests("comment.list")
        fake.resolvePending("comment.list", with: ["threads": Self.threads(101...200), "nextToken": "t2"] as [String: Any])
        try await fake.waitForPendingRequests("comment.list")
        fake.failPending("comment.list", with: PageError())
        try await fake.waitForPendingRequests("comment.list")
        #expect(store.threads.isEmpty, "nothing is published before the walk ends")
        fake.resolvePending("comment.list", with: ["threads": [[String: Any]](), "nextToken": NSNull()] as [String: Any])

        try await waitUntil("walk finished after retry") { store.threads.count == 200 }
        #expect(fake.paramsForMethod("comment.list").map { $0["nextToken"] as? String } == ["t1", "t2", "t2"])
    }

    @Test func aThreadServedAgainInALaterRoundKeepsItsNewerRow() async throws {
        let (store, fake) = try await liveStore()
        fake.responseQueueMap["comment.list"] = [
            ["threads": [Self.thread("thread-2"), Self.thread("thread-1", count: 5)], "nextToken": NSNull()]
        ]

        fake.deliverSubscriptionPush(SubscriptionPush(
            subscriptionId: "sub-1", seq: 0, snapshot: [Self.thread("thread-1", count: 4)], nextToken: "t1"
        ))

        try await waitUntil("pages merged") { store.threads.count == 2 }
        #expect(store.threads.first { $0.threadId == "thread-1" }?.commentCount == 5)
    }

    @Test func cutThreadsKeepTheirWholeThreadSummary() async throws {
        // The summary fields describe the whole thread even when the daemon
        // trims its `comments`, so iOS shows it without `comment.getThread`.
        let (store, fake) = try await liveStore()
        fake.deliverSubscriptionPush(SubscriptionPush(
            subscriptionId: "sub-1", seq: 0, snapshot: [Self.thread("thread-1", count: 4000, truncated: true)]
        ))
        #expect(store.threads.first?.commentCount == 4000)
        #expect(!fake.didCallMethod("comment.getThread"))
    }
}
