import Combine
import Foundation
@testable import Intent
import Testing

extension NoteStoreIntegrationTests {
    // MARK: - fetchNote classification

    @Test func fetchNoteFoundReturnsNote() async {
        let fake = FakeConnectionManager()
        let store = NoteStore(connectionManager: fake)
        fake.responseMap["note.get"] = [
            "note": [
                "id": "note-1",
                "title": "Note 1",
                "content": "hello",
                "createdAt": "2024-01-01T00:00:00Z",
                "updatedAt": "2024-01-01T00:00:00Z"
            ]
        ]

        let result = await store.fetchNote(noteId: "note-1", workspaceId: "ws-1")

        if case .found(let note) = result {
            #expect(note.id == "note-1")
        } else {
            Issue.record("Expected .found, got \(result)")
        }
    }

    @Test func fetchNoteNotFoundOnRpcNotFound() async {
        let fake = FakeConnectionManager()
        let store = NoteStore(connectionManager: fake)
        fake.errorMap["note.get"] = NSError(
            domain: "WebSocket",
            code: -32_602,
            userInfo: [
                NSLocalizedDescriptionKey: "not found (-32602)",
                NSError.intentErrorDataCodeKey: "not-found"
            ]
        )

        let result = await store.fetchNote(noteId: "note-gone", workspaceId: "ws-1")

        if case .notFound = result {
        } else {
            Issue.record("Expected .notFound, got \(result)")
        }
    }

    @Test func fetchNoteTransientOnBare32602() async {
        let fake = FakeConnectionManager()
        let store = NoteStore(connectionManager: fake)
        fake.errorMap["note.get"] = NSError(
            domain: "WebSocket",
            code: -32_602,
            userInfo: [NSLocalizedDescriptionKey: "Missing required parameter: noteId"]
        )

        let result = await store.fetchNote(noteId: "note-1", workspaceId: "ws-1")

        if case .transientError = result {
        } else {
            Issue.record("Expected .transientError for a -32602 without data.code == \"not-found\", got \(result)")
        }
    }

    @Test func fetchNoteTransientOnInvalidParams32602() async {
        let fake = FakeConnectionManager()
        let store = NoteStore(connectionManager: fake)
        fake.errorMap["note.get"] = NSError(
            domain: "WebSocket",
            code: -32_602,
            userInfo: [
                NSLocalizedDescriptionKey: "Missing required parameter: noteId",
                NSError.intentErrorDataCodeKey: "invalid-params"
            ]
        )

        let result = await store.fetchNote(noteId: "note-1", workspaceId: "ws-1")

        if case .transientError = result {
        } else {
            Issue.record("Expected .transientError for data.code == \"invalid-params\", got \(result)")
        }
    }

    @Test func fetchNoteArchivedTreatedAsNotFound() async {
        let fake = FakeConnectionManager()
        let store = NoteStore(connectionManager: fake)
        fake.responseMap["note.get"] = [
            "note": [
                "id": "note-1",
                "title": "Note 1",
                "content": "hello",
                "isArchived": true,
                "createdAt": "2024-01-01T00:00:00Z",
                "updatedAt": "2024-01-01T00:00:00Z"
            ]
        ]

        let result = await store.fetchNote(noteId: "note-1", workspaceId: "ws-1")

        if case .notFound = result {
        } else {
            Issue.record("Expected .notFound for archived note, got \(result)")
        }
    }

    @Test func fetchNoteTransientOnTimeout() async {
        let fake = FakeConnectionManager()
        let store = NoteStore(connectionManager: fake)
        fake.errorMap["note.get"] = NSError(
            domain: "WebSocket",
            code: -2,
            userInfo: [NSLocalizedDescriptionKey: "Request timed out"]
        )

        let result = await store.fetchNote(noteId: "note-1", workspaceId: "ws-1")

        if case .transientError = result {
        } else {
            Issue.record("Expected .transientError, got \(result)")
        }
    }

    @Test func fetchNoteTransientOnGenericError() async {
        let fake = FakeConnectionManager()
        let store = NoteStore(connectionManager: fake)
        fake.errorMap["note.get"] = NSError(
            domain: "SomeOtherDomain",
            code: -32_602,
            userInfo: [NSLocalizedDescriptionKey: "unrelated failure"]
        )

        let result = await store.fetchNote(noteId: "note-1", workspaceId: "ws-1")

        if case .transientError = result {
        } else {
            Issue.record("Expected .transientError for non-RPC error, got \(result)")
        }
    }
}

extension NoteStoreIntegrationTests {
    // MARK: - Slim note.list projection (PROTOCOL §5.2 projection: "slim")

    @Test func fetchNotesRequestsSlimProjection() async {
        let fake = FakeConnectionManager()
        let store = NoteStore(connectionManager: fake)
        fake.responseMap["note.list"] = [
            "notes": [
                [
                    "id": "note-1",
                    "title": "Note 1",
                    "contentPreview": "preview",
                    "contentLength": 900,
                    "createdAt": "2024-01-01T00:00:00Z",
                    "updatedAt": "2024-01-01T00:00:00Z"
                ]
            ]
        ]

        await store.fetchNotes(workspaceId: "ws-1")

        let params = fake.paramsForMethod("note.list")
        #expect(params.count == 1)
        #expect(params.first?["projection"] as? String == "slim")
        #expect(store.notes.count == 1)
        #expect(store.notes.first?.contentPreview == "preview")
        #expect(store.notes.first?.isContentStale == true)
    }

    @Test func fetchNotesFallsBackToFullListOn32602() async {
        let fake = FakeConnectionManager()
        let store = NoteStore(connectionManager: fake)
        fake.errorQueueMap["note.list"] = [
            NSError(
                domain: "WebSocket",
                code: -32_602,
                userInfo: [
                    NSLocalizedDescriptionKey: "Invalid params",
                    NSError.intentErrorDataCodeKey: "invalid-params"
                ]
            )
        ]
        fake.responseMap["note.list"] = [
            "notes": [
                [
                    "id": "note-1",
                    "title": "Note 1",
                    "content": "full body",
                    "createdAt": "2024-01-01T00:00:00Z",
                    "updatedAt": "2024-01-01T00:00:00Z"
                ]
            ]
        ]

        await store.fetchNotes(workspaceId: "ws-1")

        let params = fake.paramsForMethod("note.list")
        #expect(params.count == 2)
        #expect(params[0]["projection"] as? String == "slim")
        #expect(params[1]["projection"] == nil)
        #expect(store.notes.first?.content == "full body")
    }

    @Test func fetchNotesDoesNotRetryOnOtherErrors() async {
        let fake = FakeConnectionManager()
        let store = NoteStore(connectionManager: fake)
        fake.errorMap["note.list"] = NSError(
            domain: "WebSocket",
            code: -32_000,
            userInfo: [NSLocalizedDescriptionKey: "internal error"]
        )

        await store.fetchNotes(workspaceId: "ws-1")

        #expect(fake.paramsForMethod("note.list").count == 1)
        #expect(store.notes.isEmpty)
    }

    @Test func slimReListKeepsLoadedContentAtSameUpdatedAt() async {
        let fake = FakeConnectionManager()
        let store = NoteStore(connectionManager: fake)
        fake.responseMap["note.list"] = [
            "notes": [
            [
                "id": "note-1",
                "title": "Note 1",
                "content": "full body",
                "createdAt": "2024-01-01T00:00:00Z",
                "updatedAt": "2024-01-01T00:00:00Z"
            ]
            ]
        ]
        await store.fetchNotes(workspaceId: "ws-1")
        #expect(store.notes.first?.content == "full body")

        fake.responseMap["note.list"] = [
            "notes": [
            [
                "id": "note-1",
                "title": "Note 1",
                "contentPreview": "full bo",
                "contentLength": 9,
                "createdAt": "2024-01-01T00:00:00Z",
                "updatedAt": "2024-01-01T00:00:00Z"
            ]
            ]
        ]
        await store.fetchNotes(workspaceId: "ws-1")
        #expect(store.notes.first?.content == "full body")
        #expect(store.notes.first?.isContentStale == false)
    }

    @Test func slimReListDropsStaleContentOnNewerUpdatedAt() async {
        let fake = FakeConnectionManager()
        let store = NoteStore(connectionManager: fake)
        fake.responseMap["note.list"] = [
            "notes": [
            [
                "id": "note-1",
                "title": "Note 1",
                "content": "old body",
                "createdAt": "2024-01-01T00:00:00Z",
                "updatedAt": "2024-01-01T00:00:00Z"
            ]
            ]
        ]
        await store.fetchNotes(workspaceId: "ws-1")

        fake.responseMap["note.list"] = [
            "notes": [
            [
                "id": "note-1",
                "title": "Note 1",
                "contentPreview": "new bo",
                "contentLength": 8,
                "createdAt": "2024-01-01T00:00:00Z",
                "updatedAt": "2024-01-02T00:00:00Z"
            ]
            ]
        ]
        await store.fetchNotes(workspaceId: "ws-1")
        #expect(store.notes.first?.content.isEmpty == true)
        #expect(store.notes.first?.isContentStale == true)
    }

    @Test func fetchNotesHydratesStaleSpecRow() async {
        let fake = FakeConnectionManager()
        let store = NoteStore(connectionManager: fake)
        fake.responseMap["note.list"] = [
            "notes": [
                [
                    "id": "spec",
                    "title": "Spec",
                    "isDefault": true,
                    "contentPreview": "- [x] done",
                    "contentLength": 40,
                    "createdAt": "2024-01-01T00:00:00Z",
                    "updatedAt": "2024-01-01T00:00:00Z"
                ],
                [
                    "id": "note-1",
                    "title": "Note 1",
                    "contentPreview": "p",
                    "contentLength": 5,
                    "createdAt": "2024-01-01T00:00:00Z",
                    "updatedAt": "2024-01-01T00:00:00Z"
                ]
            ]
        ]
        fake.responseMap["note.get"] = [
            "note": [
                "id": "spec",
                "title": "Spec",
                "isDefault": true,
                "content": "- [x] done\n- [ ] todo item that overflows",
                "createdAt": "2024-01-01T00:00:00Z",
                "updatedAt": "2024-01-01T00:00:00Z"
            ]
        ]

        await store.fetchNotes(workspaceId: "ws-1")

        #expect(fake.didCallMethod("note.get"))
        #expect(fake.paramsForMethod("note.get").first?["noteId"] as? String == "spec")
        let spec = store.note(byId: "spec")
        #expect(spec?.content == "- [x] done\n- [ ] todo item that overflows")
        #expect(store.note(byId: "note-1")?.isContentStale == true)
    }

    @Test func fetchNoteUpsertsFullBodyIntoCachedSlimRow() async {
        let fake = FakeConnectionManager()
        let store = NoteStore(connectionManager: fake)
        fake.responseMap["note.list"] = [
            "notes": [
            [
                "id": "note-1",
                "title": "Note 1",
                "contentPreview": "pre",
                "contentLength": 20,
                "createdAt": "2024-01-01T00:00:00Z",
                "updatedAt": "2024-01-01T00:00:00Z"
            ]
            ]
        ]
        await store.fetchNotes(workspaceId: "ws-1")
        #expect(store.note(byId: "note-1")?.isContentStale == true)

        fake.responseMap["note.get"] = [
            "note": [
                "id": "note-1",
                "title": "Note 1",
                "content": "hydrated full body",
                "createdAt": "2024-01-01T00:00:00Z",
                "updatedAt": "2024-01-01T00:00:00Z"
            ]
        ]
        let result = await store.fetchNote(noteId: "note-1", workspaceId: "ws-1")
        if case .found = result {
            #expect(store.note(byId: "note-1")?.content == "hydrated full body")
        } else {
            Issue.record("Expected .found, got \(result)")
        }
    }
}
