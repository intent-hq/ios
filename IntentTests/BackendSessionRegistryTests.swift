import Foundation
@testable import Intent
import Testing

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
    private var createdBackendIDs: [BackendID?] = []

    init() throws {
        _ = TestKeychainStorage.installed
        suiteName = "BackendSessionRegistryTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        persistence = PersistenceManager(
            defaults: defaults,
            keychainStorage: InMemoryKeychainStorage()
        )
    }

    deinit {
        UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
    }

    private func makeSession(
        backendID: BackendID?,
        connection: SessionFakeConnectionManager
    ) -> BackendSession {
        let workspaceStore = WorkspaceStore(forTesting: true)
        let fileLoader = WorkspaceFileImageLoader(connection: connection)
        return BackendSession(
            backendID: backendID,
            connection: connection,
            workspaceStore: workspaceStore,
            coordinatorFactory: { [persistence] claim in
                AppCoordinator(
                    workspaceStore: workspaceStore,
                    connection: connection,
                    backendID: backendID,
                    persistence: persistence,
                    claimScreenRestoration: claim
                )
            },
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
    }

    private func makeRegistry() -> BackendSessionRegistry {
        BackendSessionRegistry { [self] backendID in
            let connection = SessionFakeConnectionManager()
            createdBackendIDs.append(backendID)
            createdConnections.append(connection)
            return makeSession(backendID: backendID, connection: connection)
        }
    }

    // MARK: - Backend session create / reuse

    @Test func attachCreatesSessionOnFirstRequest() {
        let registry = makeRegistry()
        let id = BackendID(UUID())

        let session = registry.attach(id)

        #expect(createdBackendIDs == [id])
        #expect(session.backendID == id)
        #expect(registry.attachmentCount(for: id) == 1)
        #expect(registry.session(for: id) === session)
    }

    @Test func attachReusesLiveSessionAndRefcounts() {
        let registry = makeRegistry()
        let id = BackendID(UUID())

        let first = registry.attach(id)
        let second = registry.attach(id)

        #expect(first === second)
        #expect(createdBackendIDs.count == 1)
        #expect(registry.attachmentCount(for: id) == 2)
    }

    @Test func distinctBackendsGetIsolatedSessions() {
        let registry = makeRegistry()
        let firstBackendID = BackendID(UUID())
        let secondBackendID = BackendID(UUID())

        let sessionA = registry.attach(firstBackendID)
        let sessionB = registry.attach(secondBackendID)

        #expect(sessionA !== sessionB)
        #expect(sessionA.connection !== sessionB.connection)
        #expect(sessionA.workspaceStore !== sessionB.workspaceStore)
        #expect(Set(registry.liveBackendIDs) == [firstBackendID, secondBackendID])
    }

    // MARK: - Teardown

    @Test func detachBelowLastKeepsSessionAlive() {
        let registry = makeRegistry()
        let id = BackendID(UUID())

        let session = registry.attach(id)
        _ = registry.attach(id)
        registry.detach(id)

        #expect(registry.session(for: id) === session)
        #expect(registry.attachmentCount(for: id) == 1)
        #expect(createdConnections[0].disconnectCallCount == 0)
    }

    @Test func lastDetachDisconnectsAndReleases() {
        let registry = makeRegistry()
        let id = BackendID(UUID())

        _ = registry.attach(id)
        registry.detach(id)

        #expect(createdConnections[0].disconnectCallCount == 1)
        #expect(registry.session(for: id) == nil)
        #expect(registry.attachmentCount(for: id) == 0)
        #expect(registry.liveBackendIDs.isEmpty)
    }

    @Test func reattachAfterTeardownCreatesFreshSession() {
        let registry = makeRegistry()
        let id = BackendID(UUID())

        let first = registry.attach(id)
        registry.detach(id)
        let second = registry.attach(id)

        #expect(first !== second)
        #expect(createdBackendIDs == [id, id])
        #expect(second.connection !== first.connection)
        #expect(registry.attachmentCount(for: id) == 1)
    }

    @Test func unbalancedDetachIsNoOp() {
        let registry = makeRegistry()
        let id = BackendID(UUID())

        registry.detach(id)

        #expect(createdBackendIDs.isEmpty)
        #expect(registry.attachmentCount(for: id) == 0)
    }

    @Test func detachOfOneBackendLeavesOthersAlive() {
        let registry = makeRegistry()
        let detachedBackendID = BackendID(UUID())
        let retainedBackendID = BackendID(UUID())

        _ = registry.attach(detachedBackendID)
        let retainedSession = registry.attach(retainedBackendID)
        registry.detach(detachedBackendID)

        #expect(registry.session(for: detachedBackendID) == nil)
        #expect(registry.session(for: retainedBackendID) === retainedSession)
        #expect(createdConnections[1].disconnectCallCount == 0)
    }

    // MARK: - Pairing sessions

    @Test func pairingSessionsAreFreshAndUnregistered() {
        let registry = makeRegistry()

        let first = registry.makePairingSession()
        let second = registry.makePairingSession()

        #expect(first !== second)
        #expect(first.backendID == nil)
        #expect(createdBackendIDs == [nil, nil])
        #expect(
            registry.liveBackendIDs.isEmpty,
            "Pairing sessions are owned by their window, never registered"
        )
    }

    @Test func pairingSessionDoesNotInvokeOnSessionCreated() {
        let registry = makeRegistry()
        var created: [BackendSession] = []
        registry.onSessionCreated = { created.append($0) }

        _ = registry.makePairingSession()

        #expect(
            created.isEmpty,
            "A pairing session has no backend for aggregators to observe"
        )
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
        #expect(
            disconnectCountAtTeardown == 0,
            "Teardown callback must run before the connection is dropped"
        )
    }
}

extension BackendSessionRegistryTests {
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

    @Test func onlyFirstWindowOnABackendRestoresItsLastScreen() {
        let registry = makeRegistry()
        let id = BackendID(UUID())
        persistence.saveLastScreen(
            PersistenceManager.SavedScreen(
                screen: "workspaceDetail",
                workspaceId: "ws-restore",
                agentId: nil,
                agentName: nil,
                noteId: nil,
                noteTitle: nil
            ),
            for: id.connectionID
        )

        let session = registry.attach(id)
        let first = session.makeCoordinator()
        let second = session.makeCoordinator()

        first.onConnectionSuccess()
        second.onConnectionSuccess()

        if case .workspaceDetail(let wId) = first.currentScreen {
            #expect(wId == "ws-restore")
        } else {
            Issue.record("Expected the first window on the backend to restore, got \(first.currentScreen)")
        }
        if case .workspaceList = second.currentScreen {
            // pass — duplicated windows start at the workspace list
        } else {
            Issue.record("Expected .workspaceList on the extra window, got \(second.currentScreen)")
        }
    }

    @Test func nonClaimingWindowDoesNotOverwriteSavedScreen() {
        let registry = makeRegistry()
        let id = BackendID(UUID())
        let session = registry.attach(id)
        let first = session.makeCoordinator()
        let second = session.makeCoordinator()

        first.onConnectionSuccess()
        second.onConnectionSuccess()
        first.onSelectWorkspace("ws-first")
        second.onSelectWorkspace("ws-second")

        #expect(
            persistence.loadLastScreen(for: id.connectionID)?.workspaceId == "ws-first",
            "A window without the restoration claim must not write last-screen state"
        )
    }

    @Test func windowOnAnotherBackendNeverRestoresForeignScreen() {
        let registry = makeRegistry()
        let saved = BackendID(UUID())
        persistence.saveLastScreen(
            PersistenceManager.SavedScreen(
                screen: "workspaceDetail",
                workspaceId: "ws-restore",
                agentId: nil,
                agentName: nil,
                noteId: nil,
                noteTitle: nil
            ),
            for: saved.connectionID
        )

        let session = registry.attach(BackendID(UUID()))
        let coordinator = session.makeCoordinator()
        coordinator.onConnectionSuccess()

        if case .workspaceList = coordinator.currentScreen {
            // pass — last-screen state is keyed per backend
        } else {
            Issue.record("Another backend's window must start at the workspace list, got \(coordinator.currentScreen)")
        }
    }

    @Test func backendSessionGrantsRestorationClaimOnce() {
        let registry = makeRegistry()
        let session = registry.attach(BackendID(UUID()))

        #expect(session.claimScreenRestoration())
        #expect(!session.claimScreenRestoration())
    }

    @Test func pairingSessionNeverGrantsRestorationClaim() {
        let registry = makeRegistry()
        let session = registry.makePairingSession()

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
        let firstBackendID = BackendID(UUID())
        let secondBackendID = BackendID(UUID())

        registry.markBackendsRemoved([firstBackendID, secondBackendID])

        #expect(registry.isBackendRemoved(firstBackendID))
        #expect(registry.isBackendRemoved(secondBackendID))
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

        #expect(registry.session(for: id) === session)
        #expect(
            createdConnections[0].disconnectCallCount == 0,
            "Marking drives window close; the window's detach tears down"
        )

        registry.detach(id)
        #expect(createdConnections[0].disconnectCallCount == 1)
    }

    // MARK: - Live composition

    @Test func liveSessionsGetFreshIsolatedInstances() {
        let id = BackendID(UUID())
        let session = BackendSessionRegistry.makeLiveSession(backendID: id)
        let other = BackendSessionRegistry.makeLiveSession(backendID: BackendID(UUID()))

        #expect(session.backendID == id)
        #expect(session.connection !== other.connection)
        #expect(session.workspaceStore !== other.workspaceStore)
        #expect(session.prMonitorsStore !== other.prMonitorsStore)
        #expect(session.attachmentUploadService !== other.attachmentUploadService)
        #expect(session.workspaceFileImageLoader !== other.workspaceFileImageLoader)
        #expect(session.attachmentImageLoader !== other.attachmentImageLoader)
        #expect(session.attentionCueCenter !== other.attentionCueCenter)
    }

    @Test func livePairingSessionHasNoBackend() {
        let session = BackendSessionRegistry.makeLiveSession(backendID: nil)

        #expect(session.backendID == nil)
        #expect(!session.claimScreenRestoration())
    }
}

// MARK: - BackendID

struct BackendIDTests {
    @Test func wrapsStoredConnectionID() {
        let connection = StoredConnection(
            server: PairedServer(
                hosts: ["10.0.0.1"],
                port: 4242,
                name: "daemon",
                pairedAt: Date()
            ),
            token: "tok"
        )

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
