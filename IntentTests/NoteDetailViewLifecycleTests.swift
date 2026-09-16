import Foundation
@testable import Intent
import SwiftUI
import Testing
import UIKit

/// `NoteDetailView` owns a `NoteStore` and, while on screen, has it refresh
/// the open note on every note event. That refresh must die with the view:
/// no stale `note.get` after dismissal, and the store must deallocate so its
/// event handler is unregistered (intent-hq/ios#250).
@Suite(.serialized)
@MainActor
final class NoteDetailViewLifecycleTests {
    private let persistence: PersistenceManager
    private let suiteName: String

    init() {
        _ = TestKeychainStorage.installed
        suiteName = "NoteDetailViewLifecycleTests-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            fatalError("Could not create test defaults")
        }
        defaults.removePersistentDomain(forName: suiteName)
        persistence = PersistenceManager(
            defaults: defaults,
            keychainStorage: InMemoryKeychainStorage()
        )
    }

    deinit {
        UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
    }

    @Test func dismissedNoteDetailStopsRefreshingAndReleasesItsStore() async throws {
        let fake = FakeConnectionManager()
        fake.responseMap["note.list"] = ["notes": []]
        fake.responseMap["agent.list"] = ["agents": []]
        fake.responseMap["workspace.list"] = ["workspaces": []]
        // `note.get` stays unconfigured: the fake throws, which the view
        // treats as a transient error and keeps rendering.

        weak var weakStore: NoteStore?
        var host: Host? = Host(connection: fake, persistence: persistence) { weakStore = $0 }

        // The view's `.task` ran through to event observation: the agent
        // store's handler, then the note store's (which installs the refresh).
        try await Self.waitUntil("both stores observe events") { fake.eventHandlerCount == 2 }
        #expect(weakStore != nil)
        let loads = fake.requestLog.filter { $0.method == "note.get" }.count
        #expect(loads == 1, "the initial load fetched the note once")

        // Live: a note event refreshes the open note.
        deliverNoteUpdated(on: fake)
        try await Self.waitUntil("live refresh") {
            fake.requestLog.filter { $0.method == "note.get" }.count == loads + 1
        }

        // Dismiss the screen.
        host?.tearDown()
        host = nil

        try await Self.waitUntil("NoteStore released after dismissal") { weakStore == nil }
        #expect(weakStore == nil, "the detail view's NoteStore must deallocate once the view is gone")

        // Stale: no refresh may run for a note event after dismissal.
        let afterTeardown = fake.requestLog.filter { $0.method == "note.get" }.count
        deliverNoteUpdated(on: fake)
        try await Task.sleep(nanoseconds: 300_000_000)
        #expect(
            fake.requestLog.filter { $0.method == "note.get" }.count == afterTeardown,
            "a dismissed NoteDetailView must not refetch its note on a note event"
        )
    }

    private func deliverNoteUpdated(on fake: FakeConnectionManager) {
        fake.deliverEvent(method: "events.event", params: [
            "event": ["type": "note:updated", "workspaceId": "ws-1", "noteId": "n-1"]
        ])
    }

    private static func waitUntil(
        _ what: String,
        timeout: TimeInterval = 5,
        _ condition: @MainActor () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() >= deadline {
                Issue.record("timed out waiting for \(what)")
                return
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    /// Hosts a `NoteDetailView` in a window (so `.task` / `.onDisappear`
    /// fire) and tears it down like a popped screen. Everything that could
    /// keep the view alive — root view, controller, window — lives here so
    /// dropping the host drops them all.
    @MainActor
    private final class Host {
        private var controller: UIHostingController<AnyView>?
        private var window: UIWindow?

        init(
            connection: FakeConnectionManager,
            persistence: PersistenceManager,
            observeStore: (NoteStore) -> Void
        ) {
            let fileLoader = WorkspaceFileImageLoader(connection: connection)
            let session = BackendSession(
                backendID: BackendID(UUID()),
                connection: connection,
                workspaceStore: WorkspaceStore(connectionManager: connection),
                coordinatorFactory: { _ in fatalError("coordinator is not built in these tests") },
                githubRepoStore: GitHubRepoStore(connectionManager: connection),
                creationOptionsStore: CreationOptionsStore(connectionManager: connection),
                prMonitorsStore: WorkspacePrMonitorsStore(connectionManager: connection),
                attachmentUploadService: AttachmentUploadService(connection: connection),
                workspaceFileImageLoader: fileLoader,
                attachmentImageLoader: AttachmentImageLoader(
                    connection: connection,
                    fileLoader: fileLoader
                ),
                attentionCueCenter: WorkspaceAttentionCueCenter {}
            )
            let coordinator = AppCoordinator(
                workspaceStore: session.workspaceStore,
                connection: connection,
                persistence: persistence
            )
            let view = NoteDetailView(
                noteId: "n-1",
                workspaceId: "ws-1",
                noteTitle: "Note",
                session: session
            )
            observeStore(view.noteStore)

            let controller = UIHostingController(rootView: AnyView(
                NavigationStack { view }
                    .environment(coordinator)
                    .environment(session)
            ))
            let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
            controller.view.frame = window.bounds
            controller.beginAppearanceTransition(true, animated: false)
            window.addSubview(controller.view)
            window.isHidden = false
            controller.endAppearanceTransition()
            controller.view.layoutIfNeeded()
            self.controller = controller
            self.window = window
        }

        func tearDown() {
            guard let controller, let window else { return }
            controller.beginAppearanceTransition(false, animated: false)
            controller.view.removeFromSuperview()
            window.isHidden = true
            controller.endAppearanceTransition()
            self.controller = nil
            self.window = nil
        }
    }
}
