import Foundation
@testable import Intent
import Observation
import Synchronization
import Testing

// Extracted wire fixtures intentionally mirror the daemon payloads inline.
// swiftlint:disable multiline_arguments multiline_call_arguments multiline_literal_brackets

extension NoteStoreIntegrationTests {
    @Test func cancelledFetchNoteIgnoresLateNotFound() async throws {
        let fake = FakeConnectionManager()
        let store = NoteStore(connectionManager: fake)
        fake.pendingMethods.insert("note.get")

        let fetch = Task { await store.fetchNote(noteId: "note-1", workspaceId: "ws-1") }
        for _ in 0 ..< 40 {
            if fake.didCallMethod("note.get") {
                break
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        #expect(fake.didCallMethod("note.get"))

        // The consuming task is cancelled (screen dismissed) and the daemon's
        // not-found answer resumes the request in the same MainActor turn,
        // before the transport's cancellation cleanup task runs (ios#250).
        fetch.cancel()
        fake.failPending("note.get", with: NSError(
            domain: "WebSocket", code: -32_602,
            userInfo: [NSLocalizedDescriptionKey: "not found (-32602)",
                       NSError.intentErrorDataCodeKey: "not-found"]
        ))

        let result = await fetch.value
        if case .transientError = result {
            // pass
        } else {
            Issue.record("A not-found racing cancellation must not report .notFound, got \(result)")
        }
    }

    // MARK: - Slim note.list projection (PROTOCOL §5.2 projection: "slim")

    @Test func cancelledFetchDoesNotPublishHydratedSpecBody() async throws {
        let fake = FakeConnectionManager()
        let store = NoteStore(connectionManager: fake)
        fake.responseMap["note.list"] = ["notes": [
            ["id": "spec", "title": "Spec", "isDefault": true,
             "contentPreview": "- [x] done", "contentLength": 40,
             "createdAt": "2024-01-01T00:00:00Z", "updatedAt": "2024-01-01T00:00:00Z"]
        ]]
        func fullSpec() -> [String: Any] {
            ["note": [
                "id": "spec", "title": "Spec", "isDefault": true,
                "content": "- [x] done\n- [ ] todo item that overflows",
                "createdAt": "2024-01-01T00:00:00Z", "updatedAt": "2024-01-01T00:00:00Z"
            ]]
        }

        // The list lands and publishes the slim spec row; the hydrating
        // note.get stays in flight.
        fake.pendingMethods.insert("note.get")
        let fetch = Task { await store.fetchNotes(workspaceId: "ws-1") }
        try await Task.sleep(for: .milliseconds(100))
        #expect(store.note(byId: "spec")?.isContentStale == true)
        #expect(fake.paramsForMethod("note.get").count == 1)

        let changeCount = Mutex(0)
        withObservationTracking {
            _ = store.notes
        } onChange: {
            changeCount.withLock { $0 += 1 }
        }
        // Cancel and resolve back-to-back on the main actor: the fake's
        // cancellation hop is asynchronous, so note.get resumes with the
        // real body inside an already-cancelled fetch.
        fetch.cancel()
        fake.resolvePending("note.get", with: fullSpec())
        await fetch.value

        #expect(changeCount.withLock { $0 } == 0)
        #expect(store.note(byId: "spec")?.isContentStale == true)
        #expect(store.note(byId: "spec")?.content.isEmpty == true)
        #expect(store.isLoading == false)

        // A later, uncancelled fetch hydrates normally.
        fake.pendingMethods.remove("note.get")
        fake.responseMap["note.get"] = fullSpec()
        await store.fetchNotes(workspaceId: "ws-1")
        #expect(fake.paramsForMethod("note.get").count == 2)
        #expect(store.note(byId: "spec")?.content == "- [x] done\n- [ ] todo item that overflows")
        #expect(store.note(byId: "spec")?.isContentStale == false)
    }

    // MARK: - noteChanges() stream (detail-view refresh)

    /// Consumes `store.noteChanges()` the way `NoteDetailView.task` does,
    /// counting elements. The stream is registered synchronously in `init`
    /// so no event delivered afterwards can be missed.
    @MainActor
    private final class NoteChangesProbe {
        private(set) var fired = 0
        private(set) var finished = false
        private var consumer: Task<Void, Never>?

        init(_ store: NoteStore) {
            let changes = store.noteChanges()
            consumer = Task { [weak self] in
                for await _ in changes {
                    self?.fired += 1
                }
                self?.finished = true
            }
        }

        /// Mirrors SwiftUI cancelling the view's `.task` on disappearance.
        func cancel() async {
            consumer?.cancel()
            await consumer?.value
        }
    }

    @Test func noteDeletedEventFiresNoteChanges() async throws {
        let fake = FakeConnectionManager()
        let store = NoteStore(connectionManager: fake)
        fake.responseMap["note.list"] = ["notes": []]
        store.startObservingEvents(workspaceId: "ws-1")
        let probe = NoteChangesProbe(store)

        fake.deliverEvent(method: "events.event", params: [
            "event": ["type": "note:deleted", "workspaceId": "ws-1", "noteId": "note-1"]
        ])
        try await Task.sleep(nanoseconds: 100_000_000)

        #expect(probe.fired == 1,
                "note:deleted must fire noteChanges so the detail view can re-validate")
        await probe.cancel()
    }

    // MARK: - Event allowlist (non-live fallback)

    @Test func allowlistedNoteEventRefetchesAndFiresNoteChangesWhenNotLive() async throws {
        let fake = FakeConnectionManager()
        let store = NoteStore(connectionManager: fake)
        fake.responseMap["note.list"] = ["notes": []]
        store.startObservingEvents(workspaceId: "ws-1")
        let probe = NoteChangesProbe(store)

        fake.deliverEvent(method: "events.event", params: [
            "event": ["type": "note:updated", "workspaceId": "ws-1", "noteId": "note-1"]
        ])
        try await Task.sleep(nanoseconds: 100_000_000)

        #expect(fake.didCallMethod("note.list"))
        #expect(probe.fired == 1)
        await probe.cancel()
    }

    @Test func noteCreatedRefetchesButDoesNotFireNoteChanges() async throws {
        let fake = FakeConnectionManager()
        let store = NoteStore(connectionManager: fake)
        fake.responseMap["note.list"] = ["notes": []]
        store.startObservingEvents(workspaceId: "ws-1")
        let probe = NoteChangesProbe(store)

        fake.deliverEvent(method: "events.event", params: [
            "event": ["type": "note:created", "workspaceId": "ws-1", "noteId": "note-2"]
        ])
        try await Task.sleep(nanoseconds: 100_000_000)

        #expect(fake.didCallMethod("note.list"), "a new note changes list membership")
        #expect(probe.fired == 0,
                "a newly created note can never be the open note; refreshNote is not needed")
        await probe.cancel()
    }

    @Test func nonAllowlistedEventsDoNotRefetchOrFireNoteChanges() async throws {
        let fake = FakeConnectionManager()
        let store = NoteStore(connectionManager: fake)
        fake.responseMap["note.list"] = ["notes": []]
        store.startObservingEvents(workspaceId: "ws-1")
        let probe = NoteChangesProbe(store)

        for type in ["comment:added", "comment:resolved", "note:archived", "task:status-changed"] {
            fake.deliverEvent(method: "events.event", params: [
                "event": ["type": type, "workspaceId": "ws-1", "noteId": "note-1"]
            ])
        }
        try await Task.sleep(nanoseconds: 100_000_000)

        #expect(!fake.didCallMethod("note.list"))
        #expect(probe.fired == 0)
        await probe.cancel()
    }

    // MARK: - noteChanges() teardown (ios#250)

    @Test func cancelledNoteChangesConsumerStopsReceivingEvents() async throws {
        let fake = FakeConnectionManager()
        let store = NoteStore(connectionManager: fake)
        fake.responseMap["note.list"] = ["notes": []]
        store.startObservingEvents(workspaceId: "ws-1")
        let probe = NoteChangesProbe(store)

        fake.deliverEvent(method: "events.event", params: [
            "event": ["type": "note:updated", "workspaceId": "ws-1", "noteId": "note-1"]
        ])
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(probe.fired == 1)

        await probe.cancel()
        #expect(probe.finished)

        fake.deliverEvent(method: "events.event", params: [
            "event": ["type": "note:updated", "workspaceId": "ws-1", "noteId": "note-1"]
        ])
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(probe.fired == 1, "no element may be delivered after cancellation")
    }

    @Test func storeDeallocatesAfterNoteChangesConsumerIsCancelled() async throws {
        let fake = FakeConnectionManager()
        var store: NoteStore? = NoteStore(connectionManager: fake)
        weak var weakStore = store
        fake.responseMap["note.list"] = ["notes": []]
        store?.startObservingEvents(workspaceId: "ws-1")
        #expect(fake.eventHandlerCount == 1)

        let probe = try NoteChangesProbe(#require(store))
        await probe.cancel()

        store = nil
        for _ in 0 ..< 40 {
            if weakStore == nil, fake.eventHandlerCount == 0 {
                break
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        #expect(weakStore == nil, "a subscribed-then-cancelled stream must not keep the store alive")
        #expect(fake.eventHandlerCount == 0)
    }

    @Test func storeDeinitFinishesLiveNoteChangesStreams() async throws {
        let fake = FakeConnectionManager()
        var store: NoteStore? = NoteStore(connectionManager: fake)
        let probe = try NoteChangesProbe(#require(store))

        // The consumer's loop must end rather than await a store that is gone.
        store = nil
        for _ in 0 ..< 40 {
            if probe.finished {
                break
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        #expect(probe.finished, "deinit must finish live noteChanges() streams")
        await probe.cancel()
    }

    // MARK: - deinit removes event + subscription handlers (monorepo#2211, monorepo#2213)

    // MARK: - Identical refetch stays quiet (no re-render underneath swipe-back)

    @Test func identicalRefetchDoesNotReassignNotes() async {
        let fake = FakeConnectionManager()
        let store = NoteStore(connectionManager: fake)
        fake.responseMap["note.list"] = ["notes": [
            ["id": "note-1", "title": "Note 1", "content": "",
             "createdAt": "2024-01-01T00:00:00Z", "updatedAt": "2024-01-01T00:00:00Z"]
        ]]
        await store.fetchNotes(workspaceId: "ws-1")
        #expect(store.hasLoaded == true)
        #expect(store.notes.count == 1)

        // The deferred refresh after re-appearing for the same workspace
        // returns the same list: no observed property may be invalidated.
        let changeCount = Mutex(0)
        withObservationTracking {
            _ = store.notes
            _ = store.hasLoaded
            _ = store.isLoading
        } onChange: {
            changeCount.withLock { $0 += 1 }
        }
        await store.fetchNotes(workspaceId: "ws-1")
        #expect(fake.paramsForMethod("note.list").count == 2)
        #expect(changeCount.withLock { $0 } == 0)
        #expect(store.notes.count == 1)

        // A genuinely different list must still publish.
        fake.responseMap["note.list"] = ["notes": [
            ["id": "note-1", "title": "Note 1", "content": "",
             "createdAt": "2024-01-01T00:00:00Z", "updatedAt": "2024-01-01T00:00:00Z"],
            ["id": "note-2", "title": "Note 2", "content": "",
             "createdAt": "2024-01-02T00:00:00Z", "updatedAt": "2024-01-02T00:00:00Z"]
        ]]
        await store.fetchNotes(workspaceId: "ws-1")
        #expect(changeCount.withLock { $0 } == 1)
        #expect(store.notes.map(\.id) == ["note-1", "note-2"])
    }
}

// swiftlint:enable multiline_arguments multiline_call_arguments multiline_literal_brackets
