import Foundation
import Testing
@testable import Intent

/// Session-connection fake: `FakeConnectionManager` plus the explicit
/// teardown surface `BackendSession` owns, recording disconnects.
@MainActor
final class SessionFakeConnectionManager: FakeConnectionManager, SessionConnectionManaging {
    private(set) var disconnectCallCount = 0

    func disconnect() {
        disconnectCallCount += 1
        simulateDisconnect()
    }
}

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
            coordinator: AppCoordinator(
                workspaceStore: workspaceStore, connection: connection,
                persistence: persistence),
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
        #expect(sessionA.coordinator !== sessionB.coordinator)
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
