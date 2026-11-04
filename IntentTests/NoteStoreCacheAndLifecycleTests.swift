import Combine
import Foundation
@testable import Intent
import Testing

extension NoteStoreIntegrationTests {
    @Test func fetchNoteDoesNotUpsertAcrossWorkspaces() async {
        let fake = FakeConnectionManager()
        let store = NoteStore(connectionManager: fake)
        fake.responseMap["note.list"] = [
            "notes": [
            [
                "id": "spec",
                "title": "Spec A",
                "content": "workspace A spec",
                "createdAt": "2024-01-01T00:00:00Z",
                "updatedAt": "2024-01-01T00:00:00Z"
            ]
            ]
        ]
        await store.fetchNotes(workspaceId: "ws-a")

        // A fetch for another workspace's same-id note must not clobber the
        // cache (note ids like "spec" repeat across workspaces).
        fake.responseMap["note.get"] = [
            "note": [
                "id": "spec",
                "title": "Spec B",
                "content": "workspace B spec",
                "createdAt": "2024-01-01T00:00:00Z",
                "updatedAt": "2024-01-01T00:00:00Z"
            ]
        ]
        _ = await store.fetchNote(noteId: "spec", workspaceId: "ws-b")
        #expect(store.note(byId: "spec")?.content == "workspace A spec")
    }

    @Test func fetchNoteDoesNotClobberNewerCachedRow() async {
        let fake = FakeConnectionManager()
        let store = NoteStore(connectionManager: fake)
        // Cache advanced to a newer revision (delta/re-list) while a
        // note.get was in flight: the late older response must not replace
        // the row or clear its stale marker.
        fake.responseMap["note.list"] = [
            "notes": [
            [
                "id": "note-1",
                "title": "Note 1 (new)",
                "contentPreview": "newer",
                "contentLength": 10,
                "createdAt": "2024-01-01T00:00:00Z",
                "updatedAt": "2024-01-02T00:00:00Z"
            ]
            ]
        ]
        await store.fetchNotes(workspaceId: "ws-1")

        fake.responseMap["note.get"] = [
            "note": [
                "id": "note-1",
                "title": "Note 1 (old)",
                "content": "older body",
                "createdAt": "2024-01-01T00:00:00Z",
                "updatedAt": "2024-01-01T00:00:00Z"
            ]
        ]
        let result = await store.fetchNote(noteId: "note-1", workspaceId: "ws-1")
        guard case .found(let fetched) = result else {
            Issue.record("Expected .found, got \(result)")
            return
        }
        // Caller still gets the fetched note, but the cache keeps the newer row.
        #expect(fetched.content == "older body")
        #expect(store.note(byId: "note-1")?.title == "Note 1 (new)")
        #expect(store.note(byId: "note-1")?.isContentStale == true)

        // A response at the cached revision (or newer) still replaces.
        fake.responseMap["note.get"] = [
            "note": [
                "id": "note-1",
                "title": "Note 1 (new)",
                "content": "current body",
                "createdAt": "2024-01-01T00:00:00Z",
                "updatedAt": "2024-01-02T00:00:00Z"
            ]
        ]
        _ = await store.fetchNote(noteId: "note-1", workspaceId: "ws-1")
        #expect(store.note(byId: "note-1")?.content == "current body")
        #expect(store.note(byId: "note-1")?.isContentStale == false)
    }

    @Test func upsertFullNoteGraftsBodyOntoStaleSlimRow() async {
        let fake = FakeConnectionManager()
        let store = NoteStore(connectionManager: fake)
        // Detail view fetched the note BEFORE the list landed (fetchNote's
        // inline upsert had no row to replace), then the slim list arrives.
        fake.responseMap["note.get"] = [
            "note": [
                "id": "note-1",
                "title": "Note 1",
                "content": "full body",
                "createdAt": "2024-01-01T00:00:00Z",
                "updatedAt": "2024-01-01T00:00:00Z"
            ]
        ]
        let result = await store.fetchNote(noteId: "note-1", workspaceId: "ws-1")
        guard case .found(let fetched) = result else {
            Issue.record("Expected .found, got \(result)")
            return
        }
        fake.responseMap["note.list"] = [
            "notes": [
            [
                "id": "note-1",
                "title": "Note 1",
                "contentPreview": "full b",
                "contentLength": 9,
                "createdAt": "2024-01-01T00:00:00Z",
                "updatedAt": "2024-01-01T00:00:00Z"
            ]
            ]
        ]
        await store.fetchNotes(workspaceId: "ws-1")
        #expect(store.note(byId: "note-1")?.isContentStale == true)

        store.upsertFullNote(fetched, workspaceId: "ws-1")
        #expect(store.note(byId: "note-1")?.content == "full body")
        #expect(store.note(byId: "note-1")?.isContentStale == false)
    }

    @Test func upsertFullNoteRefusesStaleBodyAndWrongWorkspace() async {
        let fake = FakeConnectionManager()
        let store = NoteStore(connectionManager: fake)
        fake.responseMap["note.list"] = [
            "notes": [
            [
                "id": "note-1",
                "title": "Note 1",
                "contentPreview": "newer",
                "contentLength": 10,
                "createdAt": "2024-01-01T00:00:00Z",
                "updatedAt": "2024-01-02T00:00:00Z"
            ]
            ]
        ]
        await store.fetchNotes(workspaceId: "ws-1")

        // Body fetched at an older revision must not clear the stale marker.
        let older = Note(
            id: "note-1",
            title: "Note 1",
            content: "older body",
            tags: [],
            isDefault: false,
            isArchived: false,
            taskStatus: nil,
            parentId: nil,
            createdAt: "2024-01-01T00:00:00Z",
            updatedAt: "2024-01-01T00:00:00Z"
        )
        store.upsertFullNote(older, workspaceId: "ws-1")
        #expect(store.note(byId: "note-1")?.content.isEmpty == true)
        #expect(store.note(byId: "note-1")?.isContentStale == true)

        // Same revision but wrong workspace: refused too.
        let current = Note(
            id: "note-1",
            title: "Note 1",
            content: "current body",
            tags: [],
            isDefault: false,
            isArchived: false,
            taskStatus: nil,
            parentId: nil,
            createdAt: "2024-01-01T00:00:00Z",
            updatedAt: "2024-01-02T00:00:00Z"
        )
        store.upsertFullNote(current, workspaceId: "ws-other")
        #expect(store.note(byId: "note-1")?.content.isEmpty == true)

        // Same revision, right workspace: grafts.
        store.upsertFullNote(current, workspaceId: "ws-1")
        #expect(store.note(byId: "note-1")?.content == "current body")
    }
}

extension NoteStoreIntegrationTests {
    // MARK: - note:deleted event triggers onNoteChanged

    @Test func noteDeletedEventTriggersOnNoteChanged() async throws {
        let fake = FakeConnectionManager()
        let store = NoteStore(connectionManager: fake)
        fake.responseMap["note.list"] = ["notes": []]
        store.startObservingEvents(workspaceId: "ws-1")

        var called = false
        store.onNoteChanged = { called = true }

        fake.deliverEvent(method: "events.event", params: [
            "event": ["type": "note:deleted", "workspaceId": "ws-1", "noteId": "note-1"]
        ])
        // note:deleted must invoke onNoteChanged so the detail view can re-validate.
        try await waitUntil("onNoteChanged") { called }
    }

    // MARK: - deinit removes event + subscription handlers (monorepo#2211, monorepo#2213)

    @Test func deinitRemovesEventHandler() async throws {
        let fake = FakeConnectionManager()
        var store: NoteStore? = NoteStore(connectionManager: fake)

        fake.responseMap["note.list"] = ["notes": []]
        fake.responseMap["note.subscribe"] = ["subscriptionId": "sub-1", "seq": 0, "snapshot": []]
        store?.startObservingEvents(workspaceId: "ws-1")
        fake.simulateConnect()
        await store?.fetchNotes(workspaceId: "ws-1")
        // The reconnect's note.subscribe registers the subscription handler.
        try await waitUntil("subscription handler") { fake.subscriptionHandlerCount == 1 }
        #expect(fake.eventHandlerCount == 1)
        #expect(fake.subscriptionHandlerCount == 1)

        store = nil
        // deinit hops to the main actor to remove the handlers; wait for that task
        try await waitUntil("handlers removed") {
            fake.eventHandlerCount == 0 && fake.subscriptionHandlerCount == 0
        }
        #expect(fake.eventHandlerCount == 0)
        #expect(fake.subscriptionHandlerCount == 0)
    }

    // MARK: - hasLoaded gating (empty state waits for first completed load)

    @Test func hasLoadedFalseUntilFirstFetchSucceeds() async throws {
        let fake = FakeConnectionManager()
        let store = NoteStore(connectionManager: fake)
        #expect(store.hasLoaded == false)

        fake.pendingMethods.insert("note.list")
        let fetch = Task { await store.fetchNotes(workspaceId: "ws-1") }
        try await fake.waitForPendingRequests("note.list")
        // Fetch in flight: still not loaded
        #expect(store.hasLoaded == false)
        #expect(store.isLoading == true)

        // An empty successful result is a legitimate empty state
        fake.resolvePending("note.list", with: ["notes": []])
        await fetch.value
        #expect(store.hasLoaded == true)
        #expect(store.isLoading == false)
        #expect(store.notes.isEmpty)
    }

    @Test func failedFetchLeavesHasLoadedFalse() async {
        let fake = FakeConnectionManager()
        let store = NoteStore(connectionManager: fake)
        // ConnectionManager.request throws immediately while the socket is
        // still connecting ("Not connected") — must not flip to empty state.
        fake.errorMap["note.list"] = NSError(
            domain: "WebSocket",
            code: -1,
            userInfo: [NSLocalizedDescriptionKey: "Not connected"]
        )

        await store.fetchNotes(workspaceId: "ws-1")

        #expect(store.hasLoaded == false)
        #expect(store.isLoading == false)
    }

    @Test func workspaceChangeResetsHasLoaded() async {
        let fake = FakeConnectionManager()
        let store = NoteStore(connectionManager: fake)
        fake.responseMap["note.list"] = [
            "notes": [
            [
                "id": "note-1",
                "title": "Note 1",
                "content": "",
                "createdAt": "2024-01-01T00:00:00Z",
                "updatedAt": "2024-01-01T00:00:00Z"
            ]
            ]
        ]
        await store.fetchNotes(workspaceId: "ws-1")
        #expect(store.hasLoaded == true)

        // Switching workspaces resets the gate; the failed fetch for the new
        // workspace keeps it false.
        fake.responseMap.removeValue(forKey: "note.list")
        fake.errorMap["note.list"] = NSError(
            domain: "WebSocket",
            code: -1,
            userInfo: [NSLocalizedDescriptionKey: "Not connected"]
        )
        await store.fetchNotes(workspaceId: "ws-2")
        #expect(store.hasLoaded == false)
        #expect(store.notes.isEmpty)
    }

    @Test func staleFetchForPreviousWorkspaceDoesNotFlipHasLoaded() async throws {
        let fake = FakeConnectionManager()
        let store = NoteStore(connectionManager: fake)
        fake.pendingMethods.insert("note.list")

        let staleFetch = Task { await store.fetchNotes(workspaceId: "ws-1") }
        try await fake.waitForPendingRequests("note.list")
        let currentFetch = Task { await store.fetchNotes(workspaceId: "ws-2") }
        try await fake.waitForPendingRequests("note.list", count: 2)

        // The stale ws-1 fetch completing must not mark ws-2 as loaded
        // nor replace ws-2's notes with ws-1's.
        fake.resolvePending(
            "note.list",
            with: [
                "notes": [
                    [
                        "id": "note-1",
                        "title": "Old",
                        "content": "",
                        "createdAt": "2024-01-01T00:00:00Z",
                        "updatedAt": "2024-01-01T00:00:00Z"
                    ]
                ]
            ]
        )
        await staleFetch.value
        #expect(store.hasLoaded == false)
        #expect(store.notes.isEmpty)

        fake.resolvePending("note.list", with: ["notes": []])
        await currentFetch.value
        #expect(store.hasLoaded == true)
    }

    @Test func prepareForWorkspaceChangeResetsSynchronously() async {
        let fake = FakeConnectionManager()
        let store = NoteStore(connectionManager: fake)
        fake.responseMap["note.list"] = [
            "notes": [
            [
                "id": "note-1",
                "title": "Note 1",
                "content": "",
                "createdAt": "2024-01-01T00:00:00Z",
                "updatedAt": "2024-01-01T00:00:00Z"
            ]
            ]
        ]
        await store.fetchNotes(workspaceId: "ws-1")
        #expect(store.hasLoaded == true)

        // Same workspace: no-op (re-appear must not flash the loading state)
        store.prepareForWorkspaceChange(to: "ws-1")
        #expect(store.hasLoaded == true)
        #expect(store.notes.count == 1)

        // Different workspace: resets synchronously, before any fetch runs
        store.prepareForWorkspaceChange(to: "ws-2")
        #expect(store.hasLoaded == false)
        #expect(store.notes.isEmpty)
    }
}
