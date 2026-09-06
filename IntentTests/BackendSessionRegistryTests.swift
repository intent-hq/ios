import Foundation
import Testing
@testable import Intent

/// Session-connection fake: `FakeConnectionManager` already implements the
/// session surface `BackendSession` owns (including disconnect recording).
typealias SessionFakeConnectionManager = FakeConnectionManager

/// Registry create/reuse/teardown semantics over a fake session factory —
/// pure unit tests, no sockets.
@Suite(.serialized)
@MainActor
final class BackendSessionRegistryTests {

    /// Per-test isolated persistence (same pattern as AppCoordinatorTests):
    /// a private UserDefaults suite plus in-memory keychain so no state
    /// leaks between tests or into the real app container.
    private let persistence: PersistenceManager
    private let suiteName: String

    /// Fakes created by the injected factory, in creation order.
    private var createdConnections: [SessionFakeConnectionManager] = []
    private var createdKinds: [BackendSession.Kind] = []

    init() {
        _ = TestKeychainStorage.installed
        suiteName = "BackendSessionRegistryTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        persistence = PersistenceManager(
            defaults: defaults, keychainStorage: InMemoryKeychainStorage())
    }

    deinit {
        UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
    }

    private func makeSession(
        kind: BackendSession.Kind, connection: SessionFakeConnectionManager
    ) -> BackendSession {
        let workspaceStore = WorkspaceStore(forTesting: true)
        let fileLoader = WorkspaceFileImageLoader(connection: connection)
        return BackendSession(
            kind: kind,
            connection: connection,
            workspaceStore: workspaceStore,
            coordinatorFactory: { [persistence] claim in
                AppCoordinator(
                    workspaceStore: workspaceStore, connection: connection,
                    persistence: persistence, claimScreenRestoration: claim)
            },
            prMonitorsStore: WorkspacePrMonitorsStore(connectionManager: connection),
            attachmentUploadService: AttachmentUploadService(connection: connection),
            workspaceFileImageLoader: fileLoader,
            attachmentImageLoader: AttachmentImageLoader(
                connection: connection, fileLoader: fileLoader),
            attentionCueCenter: WorkspaceAttentionCueCenter(playSound: {}))
    }

    private func makeRegistry() -> BackendSessionRegistry {
        BackendSessionRegistry { [self] kind in
            let connection = SessionFakeConnectionManager()
            createdKinds.append(kind)
            createdConnections.append(connection)
            return makeSession(kind: kind, connection: connection)
        }
    }

    // MARK: - Pinned session create / reuse

    @Test func attachCreatesPinnedSessionOnFirstRequest() {
        let registry = makeRegistry()
        let id = BackendID(UUID())

        let session = registry.attach(id)

        #expect(createdKinds == [.pinned(id)])
        #expect(session.pinnedBackendID == id)
        #expect(registry.attachmentCount(for: id) == 1)
        #expect(registry.pinnedSession(for: id) === session)
    }

    @Test func attachReusesLiveSessionAndRefcounts() {
        let registry = makeRegistry()
        let id = BackendID(UUID())

        let first = registry.attach(id)
        let second = registry.attach(id)

        #expect(first === second)
        #expect(createdKinds.count == 1)
        #expect(registry.attachmentCount(for: id) == 2)
    }

    @Test func distinctBackendsGetIsolatedSessions() {
        let registry = makeRegistry()
        let a = BackendID(UUID())
        let b = BackendID(UUID())

        let sessionA = registry.attach(a)
        let sessionB = registry.attach(b)

        #expect(sessionA !== sessionB)
        #expect(sessionA.connection !== sessionB.connection)
        #expect(sessionA.workspaceStore !== sessionB.workspaceStore)
        #expect(Set(registry.pinnedBackendIDs) == [a, b])
    }

    // MARK: - Teardown

    @Test func detachBelowLastKeepsSessionAlive() {
        let registry = makeRegistry()
        let id = BackendID(UUID())

        let session = registry.attach(id)
        _ = registry.attach(id)
        registry.detach(id)

        #expect(registry.pinnedSession(for: id) === session)
        #expect(registry.attachmentCount(for: id) == 1)
        #expect(createdConnections[0].disconnectCallCount == 0)
    }

    @Test func lastDetachDisconnectsAndReleases() {
        let registry = makeRegistry()
        let id = BackendID(UUID())

        _ = registry.attach(id)
        registry.detach(id)

        #expect(createdConnections[0].disconnectCallCount == 1)
        #expect(registry.pinnedSession(for: id) == nil)
        #expect(registry.attachmentCount(for: id) == 0)
        #expect(registry.pinnedBackendIDs.isEmpty)
    }

    @Test func reattachAfterTeardownCreatesFreshSession() {
        let registry = makeRegistry()
        let id = BackendID(UUID())

        let first = registry.attach(id)
        registry.detach(id)
        let second = registry.attach(id)

        #expect(first !== second)
        #expect(createdKinds == [.pinned(id), .pinned(id)])
        #expect(second.connection !== first.connection)
        #expect(registry.attachmentCount(for: id) == 1)
    }

    @Test func unbalancedDetachIsNoOp() {
        let registry = makeRegistry()
        let id = BackendID(UUID())

        registry.detach(id)

        #expect(createdKinds.isEmpty)
        #expect(registry.attachmentCount(for: id) == 0)
    }

    @Test func detachOfOneBackendLeavesOthersAlive() {
        let registry = makeRegistry()
        let a = BackendID(UUID())
        let b = BackendID(UUID())

        _ = registry.attach(a)
        let sessionB = registry.attach(b)
        registry.detach(a)

        #expect(registry.pinnedSession(for: a) == nil)
        #expect(registry.pinnedSession(for: b) === sessionB)
        #expect(createdConnections[1].disconnectCallCount == 0)
    }

    // MARK: - Default session

    @Test func defaultSessionIsCreatedOnceAndPersists() {
        let registry = makeRegistry()

        let first = registry.defaultSession
        let second = registry.defaultSession

        #expect(first === second)
        #expect(createdKinds == [.defaultSession])
        #expect(first.pinnedBackendID == nil)
        #expect(first.kind == .defaultSession)
    }

    @Test func pinnedTeardownDoesNotTouchDefaultSession() {
        let registry = makeRegistry()
        let id = BackendID(UUID())

        let defaultSession = registry.defaultSession
        _ = registry.attach(id)
        registry.detach(id)

        #expect(registry.defaultSession === defaultSession)
        #expect(createdConnections[0].disconnectCallCount == 0,
                "The default session's connection must never be torn down")
    }

    // MARK: - Session lifecycle callbacks

    @Test func attachInvokesOnSessionCreatedOncePerSession() {
        let registry = makeRegistry()
        var created: [BackendSession] = []
        registry.onSessionCreated = { created.append($0) }
        let id = BackendID(UUID())

        let session = registry.attach(id)
        _ = registry.attach(id)

        #expect(created.count == 1)
        #expect(created.first === session)
    }

    @Test func defaultSessionCreationInvokesOnSessionCreated() {
        let registry = makeRegistry()
        var created: [BackendSession] = []
        registry.onSessionCreated = { created.append($0) }

        let session = registry.defaultSession
        _ = registry.defaultSession

        #expect(created.count == 1)
        #expect(created.first === session)
    }

    @Test func lastDetachInvokesOnSessionTeardownBeforeDisconnect() {
        let registry = makeRegistry()
        let id = BackendID(UUID())
        var tornDown: [BackendSession] = []
        var disconnectCountAtTeardown: Int?
        registry.onSessionTeardown = { [self] session in
            tornDown.append(session)
            disconnectCountAtTeardown = createdConnections[0].disconnectCallCount
        }

        let session = registry.attach(id)
        _ = registry.attach(id)
        registry.detach(id)
        #expect(tornDown.isEmpty, "Only the last detach tears the session down")
        registry.detach(id)

        #expect(tornDown.count == 1)
        #expect(tornDown.first === session)
        #expect(disconnectCountAtTeardown == 0,
                "Teardown callback must run before the connection is dropped")
    }

    // MARK: - Per-window coordinators (spec decision 1b)

    @Test func coordinatorsOverOneSessionNavigateIndependently() {
        let registry = makeRegistry()
        let session = registry.attach(BackendID(UUID()))

        let first = session.makeCoordinator()
        let second = session.makeCoordinator()
        #expect(first !== second)

        first.onConnectionSuccess()
        second.onConnectionSuccess()
        first.onSelectWorkspace("ws-1")

        if case .workspaceDetail(let wId) = first.currentScreen {
            #expect(wId == "ws-1")
        } else {
            Issue.record("Expected .workspaceDetail on the navigating window, got \(first.currentScreen)")
        }
        if case .workspaceList = second.currentScreen {
            // pass — the sibling window over the same session is unaffected
        } else {
            Issue.record("Expected .workspaceList on the sibling window, got \(second.currentScreen)")
        }
        #expect(first.selectedWorkspaceId == "ws-1")
        #expect(second.selectedWorkspaceId == nil)
    }

    @Test func onlyFirstDefaultWindowRestoresLastScreen() {
        let registry = makeRegistry()
        persistence.saveLastScreen(
            PersistenceManager.SavedScreen(
                screen: "workspaceDetail", workspaceId: "ws-restore",
                agentId: nil, agentName: nil, noteId: nil, noteTitle: nil))

        let session = registry.defaultSession
        let first = session.makeCoordinator()
        let second = session.makeCoordinator()

        first.onConnectionSuccess()
        second.onConnectionSuccess()

        if case .workspaceDetail(let wId) = first.currentScreen {
            #expect(wId == "ws-restore")
        } else {
            Issue.record("Expected the first default window to restore, got \(first.currentScreen)")
        }
        if case .workspaceList = second.currentScreen {
            // pass — extra default windows start at the workspace list
        } else {
            Issue.record("Expected .workspaceList on the extra window, got \(second.currentScreen)")
        }
    }

    @Test func nonClaimingWindowDoesNotOverwriteSavedScreen() {
        let registry = makeRegistry()
        let session = registry.defaultSession
        let first = session.makeCoordinator()
        let second = session.makeCoordinator()

        first.onConnectionSuccess()
        second.onConnectionSuccess()
        first.onSelectWorkspace("ws-first")
        second.onSelectWorkspace("ws-second")

        #expect(persistence.loadLastScreen()?.workspaceId == "ws-first",
                "A window without the restoration claim must not write last-screen state")
    }

    @Test func pinnedSessionCoordinatorNeverRestoresLastScreen() {
        let registry = makeRegistry()
        persistence.saveLastScreen(
            PersistenceManager.SavedScreen(
                screen: "workspaceDetail", workspaceId: "ws-restore",
                agentId: nil, agentName: nil, noteId: nil, noteTitle: nil))

        let session = registry.attach(BackendID(UUID()))
        let coordinator = session.makeCoordinator()
        coordinator.onConnectionSuccess()

        if case .workspaceList = coordinator.currentScreen {
            // pass — pinned windows never restore the default window's screen
        } else {
            Issue.record("Pinned windows must start at the workspace list, got \(coordinator.currentScreen)")
        }
    }

    @Test func defaultSessionGrantsRestorationClaimOnce() {
        let registry = makeRegistry()
        let session = registry.defaultSession

        #expect(session.claimScreenRestoration())
        #expect(!session.claimScreenRestoration())
    }

    @Test func pinnedSessionNeverGrantsRestorationClaim() {
        let registry = makeRegistry()
        let session = registry.attach(BackendID(UUID()))

        #expect(!session.claimScreenRestoration())
    }

    // MARK: - Removed backends (spec decision 2)

    @Test func markBackendRemovedIsObservableAndIdempotent() {
        let registry = makeRegistry()
        let id = BackendID(UUID())

        #expect(!registry.isBackendRemoved(id))
        registry.markBackendRemoved(id)
        registry.markBackendRemoved(id)

        #expect(registry.isBackendRemoved(id))
        #expect(registry.removedBackendIDs == [id])
    }

    @Test func markBackendsRemovedMarksAllAtOnce() {
        let registry = makeRegistry()
        let a = BackendID(UUID())
        let b = BackendID(UUID())

        registry.markBackendsRemoved([a, b])

        #expect(registry.isBackendRemoved(a))
        #expect(registry.isBackendRemoved(b))
    }

    @Test func clearRemovedMarksUnmarksOnlyTheGivenBackends() {
        let registry = makeRegistry()
        let removed = BackendID(UUID())
        let resurrected = BackendID(UUID())

        registry.markBackendsRemoved([removed, resurrected])
        registry.clearRemovedMarks([resurrected])

        #expect(registry.isBackendRemoved(removed))
        #expect(!registry.isBackendRemoved(resurrected))
    }

    @Test func markingRemovedDoesNotTearDownTheSession() {
        let registry = makeRegistry()
        let id = BackendID(UUID())

        let session = registry.attach(id)
        registry.markBackendRemoved(id)

        #expect(registry.pinnedSession(for: id) === session)
        #expect(createdConnections[0].disconnectCallCount == 0,
                "Marking drives window close; the window's detach tears down")

        registry.detach(id)
        #expect(createdConnections[0].disconnectCallCount == 1)
    }

    // MARK: - Live composition

    @Test func liveDefaultSessionWrapsSharedInstances() {
        let session = BackendSessionRegistry.makeLiveSession(kind: .defaultSession)

        #expect(session.connection === ConnectionManager.shared)
        #expect(session.workspaceStore === WorkspaceStore.shared)
        #expect(session.prMonitorsStore === WorkspacePrMonitorsStore.shared)
        #expect(session.attachmentUploadService === AttachmentUploadService.shared)
        #expect(session.workspaceFileImageLoader === WorkspaceFileImageLoader.shared)
        #expect(session.attachmentImageLoader === AttachmentImageLoader.shared)
        #expect(session.attentionCueCenter === WorkspaceAttentionCueCenter.shared)
    }

    @Test func livePinnedSessionGetsFreshInstances() {
        let id = BackendID(UUID())
        let session = BackendSessionRegistry.makeLiveSession(kind: .pinned(id))

        #expect(session.pinnedBackendID == id)
        #expect(session.connection !== ConnectionManager.shared)
        #expect(session.workspaceStore !== WorkspaceStore.shared)
        #expect(session.prMonitorsStore !== WorkspacePrMonitorsStore.shared)
        #expect(session.attachmentUploadService !== AttachmentUploadService.shared)
        #expect(session.workspaceFileImageLoader !== WorkspaceFileImageLoader.shared)
        #expect(session.attachmentImageLoader !== AttachmentImageLoader.shared)
        #expect(session.attentionCueCenter !== WorkspaceAttentionCueCenter.shared)
    }
}

// MARK: - BackendID

struct BackendIDTests {

    @Test func wrapsStoredConnectionID() {
        let connection = StoredConnection(
            server: PairedServer(
                hosts: ["10.0.0.1"], port: 4242, name: "daemon", pairedAt: Date()),
            token: "tok")

        #expect(BackendID(connection: connection).connectionID == connection.id)
        #expect(BackendID(connection: connection) == BackendID(connection.id))
    }

    @Test func hashesByConnectionUUID() {
        let uuid = UUID()
        let counts = [BackendID(uuid): 1]

        #expect(counts[BackendID(uuid)] == 1)
        #expect(BackendID(uuid) != BackendID(UUID()))
    }

    @Test func roundTripsThroughCodable() throws {
        let id = BackendID(UUID())
        let data = try JSONEncoder().encode(id)
        let decoded = try JSONDecoder().decode(BackendID.self, from: data)

        #expect(decoded == id)
    }
}
