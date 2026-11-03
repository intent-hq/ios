import Foundation
@testable import Intent
import Testing

/// NoteStore against a bounded daemon (PROTOCOL §5.2 "Bounded note and
/// comment reads", §6.9 "Paged snapshots").
@MainActor
struct NoteStorePagingTests {
    private struct PageError: Error {}

    private static func note(_ id: String, title: String? = nil, content: String = "") -> [String: Any] {
        [
            "id": id,
            "title": title ?? "Note \(id)",
            "content": content,
            "createdAt": "2026-11-01T00:00:00Z",
            "updatedAt": "2026-11-01T00:00:00Z"
        ]
    }

    private static func notes(_ range: ClosedRange<Int>) -> [[String: Any]] {
        range.map { note("note-\($0)") }
    }

    /// Connected store with a `note.subscribe` handler registered as `sub-1`
    /// and every connect-time `note.list` read already settled.
    private func liveStore() async throws -> (NoteStore, FakeConnectionManager) {
        let fake = FakeConnectionManager()
        let store = NoteStore(connectionManager: fake)
        store.snapshotFiller.sleep = { _ in }
        fake.responseMap["note.list"] = ["notes": [[String: Any]](), "nextToken": NSNull()]
        fake.responseMap["note.subscribe"] = ["subscriptionId": "sub-1"]
        fake.responseMap["note.unsubscribe"] = [:] as [String: Any]
        fake.simulateConnect()
        await store.fetchNotes(workspaceId: "ws-1")
        try await waitUntil("note.subscribe handler registration") { fake.hasSubscriptionHandler(id: "sub-1") }
        return (store, fake)
    }

    // MARK: - note.list walk

    @Test func fetchNotesReadsEveryPage() async {
        let fake = FakeConnectionManager()
        let store = NoteStore(connectionManager: fake)
        fake.responseQueueMap["note.list"] = [
            ["notes": Self.notes(1...200), "nextToken": "t1"],
            ["notes": Self.notes(201...250), "nextToken": "t2"],
            ["notes": [[String: Any]](), "nextToken": NSNull()]
        ]

        await store.fetchNotes(workspaceId: "ws-1")

        #expect(store.notes.count == 250)
        #expect(store.hasLoaded)
        let sent = fake.paramsForMethod("note.list")
        #expect(sent.map { $0["nextToken"] as? String } == [nil, "t1", "t2"])
        #expect(sent.allSatisfy { params in
            params["projection"] as? String == "slim" && params["limit"] as? Int == PagedReads.notePageLimit
        })
    }

    @Test func fetchNotesFailingMidWalkPublishesNothing() async {
        let fake = FakeConnectionManager()
        let store = NoteStore(connectionManager: fake)
        fake.pendingMethods = ["note.list"]
        let fetch = Task { await store.fetchNotes(workspaceId: "ws-1") }
        try? await fake.waitForPendingRequests("note.list")
        fake.resolvePending("note.list", with: ["notes": Self.notes(1...200), "nextToken": "t1"] as [String: Any])
        try? await fake.waitForPendingRequests("note.list")
        fake.failPending("note.list", with: URLError(.networkConnectionLost))
        await fetch.value

        #expect(store.notes.isEmpty)
        #expect(!store.hasLoaded)
    }

    // MARK: - Paged note.subscribe snapshot

    @Test func subscribeAsksForTheMaximumPage() async throws {
        let (_, fake) = try await liveStore()
        #expect(fake.paramsForMethod("note.subscribe").last?["limit"] as? Int == PagedReads.notePageLimit)
    }

    @Test func pagedSnapshotPublishesOnceWholeWithDeltasOnTop() async throws {
        let (store, fake) = try await liveStore()
        fake.clearRequestLog()
        fake.pendingMethods = ["note.list"]

        fake.deliverSubscriptionPush(SubscriptionPush(
            subscriptionId: "sub-1", seq: 0, snapshot: Self.notes(1...200), nextToken: "t1"
        ))
        try await fake.waitForPendingRequests("note.list")
        #expect(store.snapshotFiller.isFilling)
        #expect(store.notes.isEmpty, "a partial snapshot must not replace the list")

        // A delta during the walk is newer than any later page row.
        fake.deliverSubscriptionPush(SubscriptionPush(
            subscriptionId: "sub-1",
            seq: 1,
            delta: .init(added: [], updated: [Self.note("note-201", title: "From delta")], removedIds: ["note-202"])
        ))
        #expect(store.notes.isEmpty)

        fake.resolvePending("note.list", with: [
            "notes": [Self.note("note-201", title: "Stale page row"), Self.note("note-202"), Self.note("note-203")],
            "nextToken": "t2"
        ] as [String: Any])
        try await fake.waitForPendingRequests("note.list")
        fake.resolvePending("note.list", with: ["notes": [[String: Any]](), "nextToken": NSNull()] as [String: Any])

        try await waitUntil("whole snapshot published") { store.notes.count == 202 }
        #expect(!store.snapshotFiller.isFilling)
        #expect(store.notes.first { $0.id == "note-201" }?.title == "From delta")
        #expect(!store.notes.contains { $0.id == "note-202" })
        let sent = fake.paramsForMethod("note.list")
        #expect(sent.map { $0["nextToken"] as? String } == ["t1", "t2"])
        #expect(sent.allSatisfy { $0["workspaceId"] as? String == "ws-1" && $0["projection"] == nil })
    }

    @Test func continuationRetriesAFailedPage() async throws {
        let (store, fake) = try await liveStore()
        fake.errorQueueMap["note.list"] = [PageError()]
        fake.responseQueueMap["note.list"] = [["notes": Self.notes(201...210), "nextToken": NSNull()]]

        fake.deliverSubscriptionPush(SubscriptionPush(
            subscriptionId: "sub-1", seq: 0, snapshot: Self.notes(1...200), nextToken: "t1"
        ))

        try await waitUntil("snapshot completed after retry") { store.notes.count == 210 }
        #expect(store.snapshotFiller.failures == 0)
    }

    @Test func continuationThatKeepsFailingResubscribes() async throws {
        let (store, fake) = try await liveStore()
        let subscribes = fake.paramsForMethod("note.subscribe").count
        fake.clearRequestLog()
        fake.errorMap["note.list"] = PageError()

        fake.deliverSubscriptionPush(SubscriptionPush(
            subscriptionId: "sub-1", seq: 0, snapshot: Self.notes(1...200), nextToken: "t1"
        ))

        // Three page attempts, then the resubscribe's baseline `note.list`.
        try await waitUntil("resubscribed for a fresh snapshot") {
            fake.paramsForMethod("note.subscribe").count == 1 && fake.paramsForMethod("note.list").count == 4
        }
        #expect(subscribes == 1)
        // The partial first page is shown rather than nothing.
        #expect(store.notes.count == 200)
        #expect(store.snapshotFiller.failures == 1)

        // The fresh snapshot pages through once the daemon recovers.
        #expect(fake.hasSubscriptionHandler(id: "sub-1"))
        fake.errorMap["note.list"] = nil
        fake.responseQueueMap["note.list"] = [["notes": Self.notes(201...205), "nextToken": NSNull()]]
        fake.deliverSubscriptionPush(SubscriptionPush(
            subscriptionId: "sub-1", seq: 0, snapshot: Self.notes(1...200), nextToken: "t9"
        ))
        try await waitUntil("recovered snapshot") { store.notes.count == 205 }
        #expect(store.snapshotFiller.failures == 0)
    }

    @Test func unpagedSnapshotPublishesImmediately() async throws {
        let (store, fake) = try await liveStore()
        fake.deliverSubscriptionPush(SubscriptionPush(subscriptionId: "sub-1", seq: 0, snapshot: Self.notes(1...3)))
        #expect(store.notes.count == 3)
        #expect(!store.snapshotFiller.isFilling)
        #expect(!fake.paramsForMethod("note.list").contains { $0["nextToken"] != nil })
    }

    // MARK: - Large notes

    private static func cutNote(_ content: String, from offset: Int, to end: Int, total: Int, rev: Int = 4) -> [String: Any] {
        let bytes = Array(content.utf8)
        let note: [String: Any] = [
            "id": "note-big",
            "title": "Big",
            "rev": rev,
            "content": String(bytes: bytes[offset..<end], encoding: .utf8) ?? "",
            "contentTruncated": true,
            "contentBytes": total,
            "contentOffset": offset,
            "nextContentOffset": end < total ? end : NSNull(),
            "createdAt": "2026-11-01T00:00:00Z",
            "updatedAt": "2026-11-01T00:00:00Z"
        ]
        return ["note": note]
    }

    @Test func fetchNoteJoinsACutNote() async {
        let fake = FakeConnectionManager()
        let store = NoteStore(connectionManager: fake)
        let content = String(repeating: "Größe 📝 line\n", count: 3)
        let total = content.utf8.count
        // "Größe " is 8 bytes; cut after the first line (18 bytes) and after "Größe " on the second.
        let firstLine = "Größe 📝 line\n".utf8.count
        fake.responseQueueMap["note.get"] = [
            Self.cutNote(content, from: 0, to: firstLine, total: total),
            Self.cutNote(content, from: firstLine, to: firstLine + 8, total: total),
            Self.cutNote(content, from: firstLine + 8, to: total, total: total)
        ]

        let result = await store.fetchNote(noteId: "note-big", workspaceId: "ws-1")

        guard case .found(let note) = result else {
            Issue.record("Expected .found, got \(result)")
            return
        }
        #expect(note.content == content)
        #expect(!note.contentTruncated)
        #expect(note.contentBytes == nil)
        let offsets = fake.paramsForMethod("note.get").map { $0["contentOffset"] as? Int }
        #expect(offsets == [nil, firstLine, firstLine + 8])
    }

    @Test func fetchNoteKeepsAMarkedPrefixWhenTheRestFails() async throws {
        let fake = FakeConnectionManager()
        let store = NoteStore(connectionManager: fake)
        store.pageRetrySleep = { _ in }
        let content = String(repeating: "abc\n", count: 4)
        fake.pendingMethods = ["note.get"]
        let fetch = Task { await store.fetchNote(noteId: "note-big", workspaceId: "ws-1") }
        try await fake.waitForPendingRequests("note.get")
        fake.resolvePending("note.get", with: Self.cutNote(content, from: 0, to: 8, total: 16))
        for _ in 0..<PagedReads.pageAttempts {
            try await fake.waitForPendingRequests("note.get")
            fake.failPending("note.get", with: URLError(.networkConnectionLost))
        }
        let result = await fetch.value

        guard case .found(let note) = result else {
            Issue.record("Expected .found, got \(result)")
            return
        }
        #expect(note.content == "abc\nabc\n")
        #expect(note.contentTruncated)
        #expect(note.contentBytes == 16)
        #expect(note.needsFullContent)
    }

    @Test func truncationNoticeNamesShownAndTotalSize() {
        let message = NoteTruncationNotice.message(shownBytes: 480_000, totalBytes: 1_200_000)
        #expect(message.hasPrefix("This note is only partly loaded. Showing the first "))
        #expect(message.contains(" of "))
        #expect(!NoteTruncationNotice.message(shownBytes: 10, totalBytes: nil).contains(" of "))
    }

    @Test func graftingAWholeBodyClearsTheCutMarkers() throws {
        let cut = try #require(Note.parseNote([
            "id": "note-big", "title": "Big", "content": "abc\n", "contentTruncated": true, "contentBytes": 8,
            "createdAt": "2026-11-01T00:00:00Z", "updatedAt": "2026-11-01T00:00:00Z"
        ]))
        #expect(cut.contentTruncated)
        #expect(cut.contentBytes == 8)
        #expect(cut.needsFullContent)
        let whole = Note(
            id: "note-big",
            title: "Big",
            content: "abc\ndef\n",
            tags: [],
            isDefault: false,
            isArchived: false,
            taskStatus: nil,
            parentId: nil,
            createdAt: "2026-11-01T00:00:00Z",
            updatedAt: "2026-11-01T00:00:00Z"
        )
        let grafted = cut.withBody(of: whole)
        #expect(grafted.content == "abc\ndef\n")
        #expect(!grafted.contentTruncated)
        #expect(!grafted.needsFullContent)
        // Optimistic edits keep the markers of the body they edit.
        #expect(cut.withContent("abd\n").contentTruncated)
    }
}
