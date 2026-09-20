import Foundation
@testable import Intent
import Testing

extension AppCoordinatorTests {
    /// A legacy saved record without a certificate pin must be kept for
    /// repair, while transport admission refuses it before opening a socket.
    @Test @MainActor func legacyPinlessRecordRoutesToRepairAndIsKept() throws {
        resetConnectionState()
        defer { resetConnectionState() }

        let legacy = persistence.upsertConnection(Self.makeConnection(port: 5181))
        #expect(WebSocketConnection.trustedPin(legacy.server.certFingerprint) == nil)
        persistence.setActiveConnection(id: legacy.id)
        let coordinator = AppCoordinator(
            workspaceStore: WorkspaceStore(forTesting: true),
            connection: FakeConnectionManager(),
            backendID: BackendID(legacy.id),
            persistence: persistence,
            syncedRegistry: Self.syncedRegistry(payloads: [])
        )

        coordinator.onLoadComplete()
        guard case .connecting = coordinator.currentScreen else {
            Issue.record("Expected .connecting, got \(coordinator.currentScreen)")
            return
        }

        let refusal: WebSocketTransportError
        do {
            _ = try WebSocketConnection.makeURL(
                host: legacy.server.hosts[0],
                port: legacy.server.port,
                certFingerprint: legacy.server.certFingerprint
            )
            Issue.record("Expected the pin-less record to be refused")
            return
        } catch let error as WebSocketTransportError {
            refusal = error
        }
        #expect(refusal.isMissingCertificatePin)

        coordinator.onConnectionFailed(error: refusal.localizedDescription)
        guard case let .connectionFailed(message) = coordinator.currentScreen else {
            Issue.record("Expected .connectionFailed, got \(coordinator.currentScreen)")
            return
        }
        #expect(ConnectionFailureView.isCertificateMismatchMessage(message))
        #expect(coordinator.connectionFailureRetryPolicy == .automaticConnection)

        coordinator.onReconnect()
        guard case .pairing = coordinator.currentScreen else {
            Issue.record("Expected .pairing, got \(coordinator.currentScreen)")
            return
        }
        #expect(coordinator.pairingShowsSavedConnections)

        let kept = try #require(persistence.loadConnections().first { $0.id == legacy.id })
        #expect(kept.server.hosts == ["10.0.0.1"])
        #expect(kept.server.port == 5181)
        #expect(kept.server.name == "daemon-5181")
        #expect(kept.token == "tok-5181")
    }
}

extension AppCoordinatorTests {
    private struct FailedLogOffContext {
        let storage: InMemoryKeychainStorage
        let stored: StoredConnection
        let fake: FakeConnectionManager
        let registry: BackendSessionRegistry
        let coordinator: AppCoordinator
    }

    @MainActor
    private func makeFailedLogOffContext() -> FailedLogOffContext {
        let storage = InMemoryKeychainStorage()
        persistence.keychainStorage = storage
        let stored = persistence.upsertConnection(Self.makeConnection(port: 1))
        persistence.setActiveConnection(id: stored.id)
        saveWorkspaceListScreen(for: stored)
        storage.setSaveFailure(true)
        let fake = FakeConnectionManager()
        let registry = Self.markOnlySessionRegistry()
        let coordinator = AppCoordinator(
            workspaceStore: WorkspaceStore.shared,
            connection: fake,
            backendID: BackendID(stored.id),
            persistence: persistence,
            sessionRegistry: registry
        )
        return FailedLogOffContext(
            storage: storage,
            stored: stored,
            fake: fake,
            registry: registry,
            coordinator: coordinator
        )
    }

    /// A failed Log Off stays disconnected. Its manual retry policy prevents
    /// the failure screen from dialing the saved record, while Retry Log Off
    /// retries forgetting it.
    @Test @MainActor func failedLogOffDisconnectsButKeepsSavedStateAndShowsFailure() async {
        resetConnectionState()
        defer { resetConnectionState() }
        let context = makeFailedLogOffContext()

        #expect(!context.coordinator.onLogOff())
        #expect(persistence.loadConnections() == [context.stored])
        #expect(persistence.activeConnection()?.id == context.stored.id)
        #expect(persistence.loadLastScreen(for: context.stored.id) != nil)
        #expect(!context.registry.isBackendRemoved(BackendID(context.stored.id)))
        #expect(context.fake.disconnectCallCount == 1)
        #expect(context.coordinator.connectionFailureRetryPolicy == .manualLogOff)
        guard case let .connectionFailed(message) = context.coordinator.currentScreen else {
            Issue.record("Expected persistence failure screen")
            return
        }
        #expect(message == "Could not forget this connection. Please try again.")

        var attempts = 0
        await ConnectionFailureView.runAutoRetry(
            retryPolicy: context.coordinator.connectionFailureRetryPolicy,
            isCertMismatch: false,
            coordinator: context.coordinator,
            connection: context.fake,
            loadConnections: { [persistence] in persistence.loadConnections() },
            backoff: { _ in .zero },
            onAttempt: { _ in attempts += 1 }
        )
        #expect(attempts == 0)
        #expect(context.fake.connectLog.isEmpty, "A failed Log Off must not auto-reconnect")
        #expect(persistence.loadConnections() == [context.stored])
        if case .connectionFailed = context.coordinator.currentScreen {} else {
            Issue.record("Retry lifecycle changed the failed-log-off screen")
        }

        context.storage.setSaveFailure(false)
        #expect(context.coordinator.onLogOff())
        #expect(persistence.loadConnections().isEmpty)
        #expect(context.registry.isBackendRemoved(BackendID(context.stored.id)))
        #expect(context.fake.connectLog.isEmpty)
    }

    /// Positive control: an ordinary connection failure still auto-dials the
    /// bound window's saved record.
    @Test @MainActor func ordinaryConnectionFailureStillAutoRetries() async {
        resetConnectionState()
        defer { resetConnectionState() }
        let stored = persistence.upsertConnection(Self.makeConnection(port: 1))
        persistence.setActiveConnection(id: stored.id)
        let fake = FakeConnectionManager()
        let coordinator = AppCoordinator(
            workspaceStore: WorkspaceStore.shared,
            connection: fake,
            backendID: BackendID(stored.id),
            persistence: persistence,
            syncedRegistry: Self.syncedRegistry(payloads: [])
        )

        coordinator.onConnectionFailed(error: "Connection to 10.0.0.1 timed out")
        #expect(coordinator.connectionFailureRetryPolicy == .automaticConnection)

        var attempts = 0
        await ConnectionFailureView.runAutoRetry(
            retryPolicy: coordinator.connectionFailureRetryPolicy,
            isCertMismatch: false,
            coordinator: coordinator,
            connection: fake,
            loadConnections: { [persistence] in persistence.loadConnections() },
            backoff: { _ in .zero },
            onAttempt: { _ in attempts += 1 }
        )

        #expect(attempts == 1)
        #expect(fake.connectLog.count == 1)
        #expect(fake.connectLog.first?.port == 1)
        #expect(fake.connectLog.first?.token == stored.token)
        if case .connectionFailed = coordinator.currentScreen {
            Issue.record("A successful auto-retry must route off the failure screen")
        }
    }
}
