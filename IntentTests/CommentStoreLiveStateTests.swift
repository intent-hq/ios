import Foundation
import Testing
@testable import Intent

@MainActor
struct CommentStoreLiveStateTests {
    
    // MARK: - Live-state subscription tests
    
    @Test func appliesSnapshot() async throws {
        let store = CommentStore(forTesting: true)
        let reconciler = DeltaReconciler<CommentThread>(
            getId: { dict in dict["threadId"] as? String },
            normalize: { dict in CommentThread.parseThread(dict) }
        )
        await store.setTestReconciler(reconciler)
        
        let push = SubscriptionPush(
            subscriptionId: "sub-1",
            kind: .snapshot,
            seq: 0,
            snapshot: [
                [
                    "threadId": "thread-1",
                    "noteId": "note-1",
                    "status": "open",
                    "createdAt": "2026-03-18T10:00:00Z",
                    "lastActivity": "2026-03-18T10:00:00Z",
                    "latestCommentAuthor": "User",
                    "latestCommentAuthorType": "user",
                    "latestCommentAt": "2026-03-18T10:00:00Z",
                    "commentCount": 1
                ],
                [
                    "threadId": "thread-2",
                    "noteId": "note-1",
                    "status": "open",
                    "createdAt": "2026-03-18T11:00:00Z",
                    "lastActivity": "2026-03-18T11:00:00Z",
                    "latestCommentAuthor": "Agent",
                    "latestCommentAuthorType": "agent",
                    "latestCommentAt": "2026-03-18T11:00:00Z",
                    "commentCount": 2
                ]
            ],
            delta: nil
        )
        
        store.handleEvent("subscription.push", params: [
            "subscriptionId": "sub-1",
            "kind": "snapshot",
            "seq": 0,
            "snapshot": push.snapshot ?? []
        ])
        
        #expect(store.threads.count == 2)
        #expect(store.threads[0].threadId == "thread-1")
        #expect(store.threads[1].threadId == "thread-2")
    }
    
    @Test func appliesContiguousDelta() async throws {
        let store = CommentStore(forTesting: true)
        let reconciler = DeltaReconciler<CommentThread>(
            getId: { dict in dict["threadId"] as? String },
            normalize: { dict in CommentThread.parseThread(dict) }
        )
        await store.setTestReconciler(reconciler)
        
        // First apply snapshot
        store.handleEvent("subscription.push", params: [
            "subscriptionId": "sub-1",
            "kind": "snapshot",
            "seq": 0,
            "snapshot": [
                [
                    "threadId": "thread-1",
                    "noteId": "note-1",
                    "status": "open",
                    "createdAt": "2026-03-18T10:00:00Z",
                    "lastActivity": "2026-03-18T10:00:00Z",
                    "latestCommentAuthor": "User",
                    "latestCommentAuthorType": "user",
                    "latestCommentAt": "2026-03-18T10:00:00Z",
                    "commentCount": 1
                ]
            ]
        ])
        
        #expect(store.threads.count == 1)
        
        // Now apply delta
        store.handleEvent("subscription.push", params: [
            "subscriptionId": "sub-1",
            "kind": "delta",
            "seq": 1,
            "delta": [
                "added": [
                    [
                        "threadId": "thread-2",
                        "noteId": "note-1",
                        "status": "open",
                        "createdAt": "2026-03-18T11:00:00Z",
                        "lastActivity": "2026-03-18T11:00:00Z",
                        "latestCommentAuthor": "Agent",
                        "latestCommentAuthorType": "agent",
                        "latestCommentAt": "2026-03-18T11:00:00Z",
                        "commentCount": 1
                    ]
                ],
                "updated": [],
                "removedIds": []
            ]
        ])
        
        #expect(store.threads.count == 2)
        #expect(store.threads[0].threadId == "thread-1")
        #expect(store.threads[1].threadId == "thread-2")
    }
    
    @Test func detectsGapAndReturnsFalse() async throws {
        let store = CommentStore(forTesting: true)
        let reconciler = DeltaReconciler<CommentThread>(
            getId: { dict in dict["threadId"] as? String },
            normalize: { dict in CommentThread.parseThread(dict) }
        )
        await store.setTestReconciler(reconciler)
        
        // Apply snapshot
        store.handleEvent("subscription.push", params: [
            "subscriptionId": "sub-1",
            "kind": "snapshot",
            "seq": 0,
            "snapshot": [
                [
                    "threadId": "thread-1",
                    "noteId": "note-1",
                    "status": "open",
                    "createdAt": "2026-03-18T10:00:00Z",
                    "lastActivity": "2026-03-18T10:00:00Z",
                    "latestCommentAuthor": "User",
                    "latestCommentAuthorType": "user",
                    "latestCommentAt": "2026-03-18T10:00:00Z",
                    "commentCount": 1
                ]
            ]
        ])

        let initialCount = store.threads.count

        // Apply delta with gap (seq 5 instead of 1)
        store.handleEvent("subscription.push", params: [
            "subscriptionId": "sub-1",
            "kind": "delta",
            "seq": 5,
            "delta": [
                "added": [],
                "updated": [],
                "removedIds": []
            ]
        ])

        // Thread count should remain unchanged (gap not applied)
        #expect(store.threads.count == initialCount)
    }

    @Test func resetsOnReconnect() async throws {
        let store = CommentStore(forTesting: true)
        let reconciler = DeltaReconciler<CommentThread>(
            getId: { dict in dict["threadId"] as? String },
            normalize: { dict in CommentThread.parseThread(dict) }
        )
        await store.setTestReconciler(reconciler)

        // Apply snapshot
        store.handleEvent("subscription.push", params: [
            "subscriptionId": "sub-1",
            "kind": "snapshot",
            "seq": 0,
            "snapshot": [
                [
                    "threadId": "thread-1",
                    "noteId": "note-1",
                    "status": "open",
                    "createdAt": "2026-03-18T10:00:00Z",
                    "lastActivity": "2026-03-18T10:00:00Z",
                    "latestCommentAuthor": "User",
                    "latestCommentAuthorType": "user",
                    "latestCommentAt": "2026-03-18T10:00:00Z",
                    "commentCount": 1
                ]
            ]
        ])

        #expect(store.threads.count == 1)

        // Simulate reconnect by creating new reconciler
        let newReconciler = DeltaReconciler<CommentThread>(
            getId: { dict in dict["threadId"] as? String },
            normalize: { dict in CommentThread.parseThread(dict) }
        )
        await store.setTestReconciler(newReconciler)

        // New snapshot should replace old state
        store.handleEvent("subscription.push", params: [
            "subscriptionId": "sub-2",
            "kind": "snapshot",
            "seq": 0,
            "snapshot": [
                [
                    "threadId": "thread-2",
                    "noteId": "note-1",
                    "status": "open",
                    "createdAt": "2026-03-18T12:00:00Z",
                    "lastActivity": "2026-03-18T12:00:00Z",
                    "latestCommentAuthor": "Agent",
                    "latestCommentAuthorType": "agent",
                    "latestCommentAt": "2026-03-18T12:00:00Z",
                    "commentCount": 1
                ]
            ]
        ])

        #expect(store.threads.count == 1)
        #expect(store.threads[0].threadId == "thread-2")
    }

    @Test func rejectsMalformedPush() async throws {
        let store = CommentStore(forTesting: true)
        let reconciler = DeltaReconciler<CommentThread>(
            getId: { dict in dict["threadId"] as? String },
            normalize: { dict in CommentThread.parseThread(dict) }
        )
        await store.setTestReconciler(reconciler)

        // Malformed snapshot push (missing snapshot field)
        store.handleEvent("subscription.push", params: [
            "subscriptionId": "sub-1",
            "kind": "snapshot",
            "seq": 0
        ])

        #expect(store.threads.count == 0)

        // Malformed delta push (missing delta field)
        store.handleEvent("subscription.push", params: [
            "subscriptionId": "sub-1",
            "kind": "delta",
            "seq": 1
        ])

        #expect(store.threads.count == 0)
    }
}
