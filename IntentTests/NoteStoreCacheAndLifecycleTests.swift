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
        #expect(fetched.content == "older body")
        #expect(store.note(byId: "note-1")?.title == "Note 1 (new)")
        #expect(store.note(byId: "note-1")?.isContentStale == true)

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

        store.upsertFullNote(current, workspaceId: "ws-1")
        #expect(store.note(byId: "note-1")?.content == "current body")
    }
}

extension NoteStoreIntegrationTests {
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
        try await waitUntil("onNoteChanged") { called }
    }

    @Test func deinitRemovesEventHandler() async throws {
        let fake = FakeConnectionManager()
        var store: NoteStore? = NoteStore(connectionManager: fake)

        fake.responseMap["note.list"] = ["notes": []]
        fake.responseMap["note.subscribe"] = ["subscriptionId": "sub-1", "seq": 0, "snapshot": []]
        store?.startObservingEvents(workspaceId: "ws-1")
        fake.simulateConnect()
        await store?.fetchNotes(workspaceId: "ws-1")
        try await waitUntil("subscription handler") { fake.subscriptionHandlerCount == 1 }
        #expect(fake.eventHandlerCount == 1)
        #expect(fake.subscriptionHandlerCount == 1)

        store = nil
        try await waitUntil("handlers removed") {
            fake.eventHandlerCount == 0 && fake.subscriptionHandlerCount == 0
        }
        #expect(fake.eventHandlerCount == 0)
        #expect(fake.subscriptionHandlerCount == 0)
    }

    @Test func hasLoadedFalseUntilFirstFetchSucceeds() async throws {
        let fake = FakeConnectionManager()
        let store = NoteStore(connectionManager: fake)
        #expect(store.hasLoaded == false)

        fake.pendingMethods.insert("note.list")
        let fetch = Task { await store.fetchNotes(workspaceId: "ws-1") }
        try await fake.waitForPendingRequests("note.list")
        #expect(store.hasLoaded == false)
        #expect(store.isLoading == true)

        fake.resolvePending("note.list", with: ["notes": []])
        await fetch.value
        #expect(store.hasLoaded == true)
        #expect(store.isLoading == false)
        #expect(store.notes.isEmpty)
    }

    @Test func failedFetchLeavesHasLoadedFalse() async {
        let fake = FakeConnectionManager()
        let store = NoteStore(connectionManager: fake)
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

        store.prepareForWorkspaceChange(to: "ws-1")
        #expect(store.hasLoaded == true)
        #expect(store.notes.count == 1)

        store.prepareForWorkspaceChange(to: "ws-2")
        #expect(store.hasLoaded == false)
        #expect(store.notes.isEmpty)
    }

    @Test func overlappingSameWorkspaceFetchDropsOlderReplyAndKeepsIsLoadingUntilLatestFinishes() async throws {
        let fake = FakeConnectionManager()
        let store = NoteStore(connectionManager: fake)
        fake.pendingMethods.insert("note.list")

        let older = Task { await store.fetchNotes(workspaceId: "ws-1") }
        try await fake.waitForPendingRequests("note.list", count: 1)
        let newer = Task { await store.fetchNotes(workspaceId: "ws-1") }
        try await fake.waitForPendingRequests("note.list", count: 2)
        #expect(store.isLoading)

        fake.resolvePending("note.list", with: [
            "notes": [["id": "stale", "title": "Stale", "content": "", "createdAt": "", "updatedAt": ""]]
        ])
        await older.value
        #expect(store.notes.isEmpty)
        #expect(store.isLoading, "isLoading must stay true until the latest fetch finishes")

        fake.resolvePending("note.list", with: [
            "notes": [["id": "fresh", "title": "Fresh", "content": "", "createdAt": "", "updatedAt": ""]]
        ])
        await newer.value
        #expect(store.notes.map(\.id) == ["fresh"])
        #expect(!store.isLoading)
    }
}
