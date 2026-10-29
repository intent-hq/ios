import Foundation
import Security
import Testing

@testable import Intent

struct BackendRoutePublicationTests {
    @Test func routeLearnedAfterInitialRefreshFailurePublishesAndRotates() async throws {
        let store = try BackendSyncTestStore()
        defer { store.cleanUp() }
        // The first refresh learns no route. Pairing still publishes successfully.
        let live = FakeConnectionManager()
        let target = server(route: nil)
        try live.connect(hosts: target.hosts, port: target.port, token: "local-token", certFingerprint: target.certFingerprint, tcAddress: nil)
        let paired = try await ConnectionPairing.finalize(
            server: server(route: nil),
            token: "local-token",
            connection: live,
            persistence: store.manager
        )
        let maxTaskYields = 20
        for _ in 0..<maxTaskYields where store.cloud.writeCount == 0 { await Task.yield() }
        #expect(store.cloud.writeCount == 1)
        #expect(try store.cloud.object()["tcAddress"] is NSNull)
        #expect(store.manager.updateConnectionTcAddress(id: paired.id, tcAddress: "tcLearned"))
        #expect(try store.cloud.object()["tcAddress"] as? String == "tcLearned")
        #expect(store.manager.updateConnectionTcAddress(id: paired.id, tcAddress: "tcRoTaTeD"))
        #expect(try store.cloud.object()["tcAddress"] as? String == "tcRoTaTeD")
        let registry = SyncedBackendRegistry(keychain: store.cloud, accessGroup: BackendSyncFixtures.accessGroup)
        guard case .available(let records) = registry.listBackends() else {
            Issue.record("Expected the second client to read the route")
            return
        }
        #expect(SyncedBackendConnectionMerge.merge(records: records, into: []).connections.first?.server.tcAddress == "tcRoTaTeD")
        #expect(store.manager.activeConnection()?.pendingRoutePublication == nil)
    }

    @Test func failedRoutePublicationRetriesAfterRelaunch() throws {
        let store = try BackendSyncTestStore()
        defer { store.cleanUp() }
        #expect(store.manager.saveVerifiedOwnerForTesting(server: server(route: "tcOld"), token: "local-token"))
        let original = try #require(store.manager.activeConnection())
        store.cloud.writeFailure = errSecNotAvailable
        #expect(store.manager.updateConnectionTcAddress(id: original.id, tcAddress: "tcNew"))
        let pending = try #require(store.manager.activeConnection()?.pendingRoutePublication)
        #expect(try store.cloud.object()["tcAddress"] as? String == "tcOld")
        let relaunched = PersistenceManager(
            defaults: store.defaults,
            keychainStorage: store.local,
            backendPublisher: BackendSyncFixtures.publisher(store.cloud, clock: 9000)
        )
        store.cloud.writeFailure = nil
        relaunched.publishPendingBackends()
        #expect(try store.cloud.object()["tcAddress"] as? String == "tcNew")
        #expect(try store.cloud.object()["updatedAt"] as? Double == pending.updatedAt)
        #expect(relaunched.activeConnection()?.pendingRoutePublication == nil)
    }

    @Test func failedLocalRouteSaveCannotPublish() throws {
        let store = try BackendSyncTestStore()
        defer { store.cleanUp() }
        #expect(store.manager.saveVerifiedOwnerForTesting(server: server(route: "tcOld"), token: "local-token"))
        let original = try #require(store.manager.activeConnection())
        store.local.setSaveFailure(true)
        #expect(!store.manager.updateConnectionTcAddress(id: original.id, tcAddress: "tcUnsaved"))
        store.manager.publishPendingBackends()
        #expect(store.cloud.writeCount == 1)
        #expect(try store.cloud.object()["tcAddress"] as? String == "tcOld")
        #expect(store.manager.activeConnection()?.pendingRoutePublication == nil)
    }

    @Test func routeAcknowledgementFailureDoesNotRepeatCloudWrite() throws {
        let store = try BackendSyncTestStore()
        defer { store.cleanUp() }
        #expect(store.manager.saveVerifiedOwnerForTesting(server: server(route: "tcOld"), token: "local-token"))
        let original = try #require(store.manager.activeConnection())
        store.cloud.beforeWrite = { store.local.setSaveFailure(true) }
        #expect(store.manager.updateConnectionTcAddress(id: original.id, tcAddress: "tcNew"))
        #expect(store.manager.activeConnection()?.pendingRoutePublication != nil)
        #expect(store.cloud.writeCount == 2)
        store.cloud.beforeWrite = nil
        store.local.setSaveFailure(false)
        store.manager.publishPendingBackends()
        #expect(store.cloud.writeCount == 2)
        #expect(store.manager.activeConnection()?.pendingRoutePublication == nil)
    }

    @Test func routeCapturePreservesNewerSharedCredentialsAndMetadata() throws {
        let store = try BackendSyncTestStore()
        defer { store.cleanUp() }
        #expect(store.manager.saveVerifiedOwnerForTesting(server: server(route: "tcOld"), token: "old-token"))
        let original = try #require(store.manager.activeConnection())
        var remote = BackendSyncFixtures.remote(clock: 3000)
        remote["tcAddress"] = "tcOld"
        try store.cloud.put(remote)
        #expect(store.manager.updateConnectionTcAddress(id: original.id, tcAddress: "tcNew"))
        let payload = try store.cloud.object()
        #expect(payload["tcAddress"] as? String == "tcNew")
        #expect(payload["token"] as? String == "remote-token")
        #expect(payload["label"] as? String == "Desktop name")
        #expect(payload["updatedAt"] as? Double == 3001)
        #expect(payload["accent"] as? String == "blue")
        let metadata = try JSONSerialization.data(withJSONObject: #require(payload["futureMetadata"]), options: [.sortedKeys])
        let expected = try JSONSerialization.data(withJSONObject: #require(remote["futureMetadata"]), options: [.sortedKeys])
        #expect(metadata == expected)
        let live = FakeConnectionManager()
        let coordinator = coordinator(store, live: live, id: original.id)
        #expect(coordinator.refreshSyncedBackends()?.updatedIds == [original.id])
        #expect(store.manager.activeConnection()?.token == "remote-token")
        #expect(live.updateCachedCredentialsLog.last?.token == "remote-token")
        #expect(live.updateCachedCredentialsLog.last?.tcAddress == "tcNew")
    }

    @Test(arguments: [1001.0, 3000.0])
    func equalOrNewerSharedRouteWinsOverPendingAutomaticRotation(clock: Double) throws {
        let store = try BackendSyncTestStore()
        defer { store.cleanUp() }
        #expect(store.manager.saveVerifiedOwnerForTesting(server: server(route: "tcOld"), token: "old-token"))
        let original = try #require(store.manager.activeConnection())
        store.cloud.writeFailure = errSecNotAvailable
        #expect(store.manager.updateConnectionTcAddress(id: original.id, tcAddress: "tcLocalRotation"))
        try store.cloud.put(BackendSyncFixtures.remote(clock: clock))
        store.cloud.writeFailure = nil
        let live = FakeConnectionManager()
        let coordinator = coordinator(store, live: live, id: original.id)
        coordinator.refreshSyncedBackends()
        #expect(store.cloud.writeCount == 2)
        #expect(try store.cloud.object()["tcAddress"] as? String == "tcDesktop")
        #expect(store.manager.activeConnection()?.server.tcAddress == "tcDesktop")
        #expect(store.manager.activeConnection()?.pendingRoutePublication == nil)
        #expect(live.updateCachedCredentialsLog.last?.tcAddress == "tcDesktop")
    }

    @Test func newerLocalObservationReplacesOlderSharedRotationWithoutLosingMetadata() throws {
        let store = try BackendSyncTestStore()
        defer { store.cleanUp() }
        #expect(store.manager.saveVerifiedOwnerForTesting(server: server(route: "tcOld"), token: "old-token"))
        let original = try #require(store.manager.activeConnection())
        var remote = BackendSyncFixtures.remote(clock: 2000)
        remote["tcAddress"] = "tcMiddle"
        try store.cloud.put(remote)
        let later = PersistenceManager(
            defaults: store.defaults,
            keychainStorage: store.local,
            backendPublisher: BackendSyncFixtures.publisher(store.cloud, clock: 3000)
        )
        #expect(later.updateConnectionTcAddress(id: original.id, tcAddress: "tcNewest"))
        let payload = try store.cloud.object()
        #expect(payload["updatedAt"] as? Double == 3000)
        #expect(payload["tcAddress"] as? String == "tcNewest")
        #expect(payload["token"] as? String == "remote-token")
        #expect(payload["label"] as? String == "Desktop name")
        #expect(payload["accent"] as? String == "blue")
        let live = FakeConnectionManager()
        #expect(coordinator(store, live: live, id: original.id).refreshSyncedBackends()?.updatedIds == [original.id])
        #expect(later.activeConnection()?.server.tcAddress == "tcNewest")
        #expect(later.activeConnection()?.token == "remote-token")
        #expect(live.updateCachedCredentialsLog.last?.tcAddress == "tcNewest")
        let registry = SyncedBackendRegistry(keychain: store.cloud, accessGroup: BackendSyncFixtures.accessGroup)
        guard case .available(let records) = registry.listBackends() else {
            Issue.record("Expected the second client to read the latest route")
            return
        }
        let imported = try #require(SyncedBackendConnectionMerge.merge(records: records, into: []).connections.first)
        #expect(imported.server.tcAddress == "tcNewest")
        #expect(imported.token == "remote-token")
    }

    @Test func pendingRouteSurvivesImportWhileCloudWriteFails() throws {
        let store = try BackendSyncTestStore()
        defer { store.cleanUp() }
        #expect(store.manager.saveVerifiedOwnerForTesting(server: server(route: "tcOld"), token: "old-token"))
        let original = try #require(store.manager.activeConnection())
        store.cloud.writeFailure = errSecNotAvailable
        #expect(store.manager.updateConnectionTcAddress(id: original.id, tcAddress: "tcNew"))
        var remote = BackendSyncFixtures.remote(clock: 3000)
        remote["tcAddress"] = "tcOld"
        try store.cloud.put(remote)
        let live = FakeConnectionManager()
        let coordinator = coordinator(store, live: live, id: original.id)
        coordinator.refreshSyncedBackends()
        #expect(store.manager.activeConnection()?.token == "remote-token")
        #expect(store.manager.activeConnection()?.principal == original.principal)
        #expect(store.manager.activeConnection()?.pendingRoutePublication != nil)
        store.cloud.writeFailure = nil
        coordinator.refreshSyncedBackends()
        #expect(try store.cloud.object()["token"] as? String == "remote-token")
        #expect(try store.cloud.object()["tcAddress"] as? String == "tcNew")
        #expect(store.manager.activeConnection()?.server.tcAddress == "tcNew")
        #expect(store.manager.activeConnection()?.pendingRoutePublication == nil)
        #expect(live.updateCachedCredentialsLog.last?.token == "remote-token")
        #expect(live.updateCachedCredentialsLog.last?.tcAddress == "tcNew")
    }

    @Test func removedBackendCannotBeRepublishedByLateRouteCapture() throws {
        let store = try BackendSyncTestStore()
        defer { store.cleanUp() }
        #expect(store.manager.saveVerifiedOwnerForTesting(server: server(route: "tcOld"), token: "local-token"))
        let original = try #require(store.manager.activeConnection())
        try store.cloud.put(BackendSyncFixtures.remote(clock: 3000, deleted: true))
        store.cloud.beforeList = { _ in store.local.setSaveFailure(true) }
        #expect(store.manager.updateConnectionTcAddress(id: original.id, tcAddress: "tcNew"))
        store.cloud.beforeList = nil
        store.cloud.items.removeAll()
        store.local.setSaveFailure(false)
        let relaunched = PersistenceManager(
            defaults: store.defaults,
            keychainStorage: store.local,
            backendPublisher: BackendSyncFixtures.publisher(store.cloud)
        )
        #expect(relaunched.updateConnectionTcAddress(id: original.id, tcAddress: "tcLater"))
        relaunched.publishPendingBackends()
        #expect(store.cloud.items.isEmpty)
        #expect(store.cloud.writeCount == 1)
        #expect(relaunched.saveVerifiedOwnerForTesting(server: server(route: "tcDeliberate"), token: "new-pairing"))
        #expect(try store.cloud.object()["tcAddress"] as? String == "tcDeliberate")
        #expect(try store.cloud.object()["updatedAt"] as? Double == 3001)
    }

    @Test func routeCaptureNeverCreatesMissingSharedRowOrExportsImportedRecord() throws {
        let store = try BackendSyncTestStore()
        defer { store.cleanUp() }
        #expect(store.manager.saveVerifiedOwnerForTesting(server: server(route: "tcOld"), token: "local-token"))
        let original = try #require(store.manager.activeConnection())
        store.cloud.items.removeAll()
        #expect(store.manager.updateConnectionTcAddress(id: original.id, tcAddress: "tcNew"))
        #expect(store.cloud.items.isEmpty)
        #expect(store.cloud.writeCount == 1)
        var imported = original
        imported.localPairingSyncClock = nil
        imported.pendingRoutePublication = nil
        try store.seed([imported])
        #expect(store.manager.updateConnectionTcAddress(id: imported.id, tcAddress: "tcImportedLocal"))
        #expect(store.manager.activeConnection()?.pendingRoutePublication == nil)
        #expect(store.cloud.writeCount == 1)
    }

    @Test func hostOnlyCapturePreservesSharedTunnelAndToken() throws {
        let store = try BackendSyncTestStore()
        defer { store.cleanUp() }
        #expect(store.manager.saveVerifiedOwnerForTesting(server: server(route: "tcOld"), token: "old-token"))
        let original = try #require(store.manager.activeConnection())
        try store.cloud.put(BackendSyncFixtures.remote(clock: 3000))
        #expect(store.manager.updateConnectionHosts(id: original.id, hosts: ["Mac.Local", "10.0.0.2"]))
        let payload = try store.cloud.object()
        #expect(payload["tcAddress"] as? String == "tcDesktop")
        #expect(payload["token"] as? String == "remote-token")
        #expect(payload["hosts"] as? [String] == ["mac.local", "10.0.0.1", "10.0.0.2"])
    }

    @Test func routeRetryCannotSupersedeStillPendingDeliberateTokenRotation() throws {
        let store = try BackendSyncTestStore()
        defer { store.cleanUp() }
        #expect(store.manager.saveVerifiedOwnerForTesting(server: server(route: "tcOld"), token: "old-token"))
        store.cloud.writeFailure = errSecNotAvailable
        #expect(store.manager.saveVerifiedOwnerForTesting(server: server(route: "tcOld"), token: "new-token"))
        let pending = try #require(store.manager.activeConnection())
        #expect(store.manager.updateConnectionTcAddress(id: pending.id, tcAddress: "tcNew"))
        #expect(store.cloud.writeCount == 3)
        #expect(try store.cloud.object()["token"] as? String == "old-token")
        store.cloud.writeFailure = nil
        store.manager.publishPendingBackends()
        #expect(store.cloud.writeCount == 4)
        #expect(try store.cloud.object()["token"] as? String == "new-token")
        #expect(try store.cloud.object()["tcAddress"] as? String == "tcNew")
        #expect(store.manager.activeConnection()?.pendingSyncUpdatedAt == nil)
        #expect(store.manager.activeConnection()?.pendingRoutePublication == nil)
    }

    private func server(route: String?) -> PairedServer {
        let original = BackendSyncFixtures.local().server
        return PairedServer(
            hosts: original.hosts,
            port: original.port,
            name: original.name,
            pairedAt: original.pairedAt,
            certFingerprint: original.certFingerprint,
            tcAddress: route
        )
    }

    private func coordinator(_ store: BackendSyncTestStore, live: FakeConnectionManager, id: UUID) -> AppCoordinator {
        AppCoordinator(
            workspaceStore: WorkspaceStore(forTesting: true),
            connection: live,
            backendID: BackendID(id),
            persistence: store.manager,
            syncedRegistry: SyncedBackendRegistry(keychain: store.cloud, accessGroup: BackendSyncFixtures.accessGroup)
        )
    }
}

extension BackendRoutePublicationTests {
    @Test(arguments: [false, true])
    func hostUpdateDoesNotRestampFailedTunnelObservation(useLegacyIntent: Bool) throws {
        let store = try BackendSyncTestStore()
        defer { store.cleanUp() }
        #expect(store.manager.saveVerifiedOwnerForTesting(server: server(route: "tcOld"), token: "old-token"))
        let original = try #require(store.manager.activeConnection())
        store.cloud.writeFailure = errSecNotAvailable
        #expect(store.manager.updateConnectionTcAddress(id: original.id, tcAddress: "tcA"))
        if useLegacyIntent { try removeTunnelClockFromSavedIntent(store) }
        var remote = BackendSyncFixtures.remote(clock: 2000)
        remote["tcAddress"] = "tcB"
        try store.cloud.put(remote)
        let later = PersistenceManager(
            defaults: store.defaults,
            keychainStorage: store.local,
            backendPublisher: BackendSyncFixtures.publisher(store.cloud, clock: 3000)
        )
        #expect(later.updateConnectionHosts(id: original.id, hosts: ["Mac.Local", "10.0.0.2"]))
        #expect(later.activeConnection()?.pendingRoutePublication?.updatedAt == 3000)
        #expect(later.activeConnection()?.pendingRoutePublication?.tcUpdatedAt == 1001)
        #expect(try store.cloud.object()["tcAddress"] as? String == "tcB")
        let relaunched = PersistenceManager(
            defaults: store.defaults,
            keychainStorage: store.local,
            backendPublisher: BackendSyncFixtures.publisher(store.cloud, clock: 9000)
        )
        store.cloud.writeFailure = nil
        let live = FakeConnectionManager()
        let coordinator = AppCoordinator(
            workspaceStore: WorkspaceStore(forTesting: true),
            connection: live,
            backendID: BackendID(original.id),
            persistence: relaunched,
            syncedRegistry: SyncedBackendRegistry(keychain: store.cloud, accessGroup: BackendSyncFixtures.accessGroup)
        )
        #expect(coordinator.refreshSyncedBackends()?.updatedIds == [original.id])
        #expect(relaunched.activeConnection()?.server.tcAddress == "tcB")
        #expect(relaunched.activeConnection()?.pendingRoutePublication == nil)
        #expect(live.updateCachedCredentialsLog.last?.tcAddress == "tcB")
        #expect(live.updateCachedCredentialsLog.last?.hosts.contains("10.0.0.2") == true)
        try verifyHostOnlyRetry(store)
    }

    private func removeTunnelClockFromSavedIntent(_ store: BackendSyncTestStore) throws {
        let stored = try #require(store.manager.activeConnection())
        let data = try JSONEncoder().encode(stored)
        var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var pending = try #require(object["pendingRoutePublication"] as? [String: Any])
        pending["tcUpdatedAt"] = nil
        object["pendingRoutePublication"] = pending
        let legacy = try JSONDecoder().decode(StoredConnection.self, from: JSONSerialization.data(withJSONObject: object))
        try store.seed([legacy])
    }

    private func verifyHostOnlyRetry(_ store: BackendSyncTestStore) throws {
        let payload = try store.cloud.object()
        let hostObservationClock = 3000.0
        #expect(payload["tcAddress"] as? String == "tcB")
        #expect(payload["updatedAt"] as? Double == hostObservationClock)
        #expect(payload["hosts"] as? [String] == ["mac.local", "10.0.0.1", "10.0.0.2"])
        #expect(payload["token"] as? String == "remote-token")
        #expect(payload["label"] as? String == "Desktop name")
        let registry = SyncedBackendRegistry(keychain: store.cloud, accessGroup: BackendSyncFixtures.accessGroup)
        guard case .available(let records) = registry.listBackends() else {
            Issue.record("Expected the second client to read the new hosts and winning tunnel")
            return
        }
        let imported = try #require(SyncedBackendConnectionMerge.merge(records: records, into: []).connections.first)
        #expect(imported.server.tcAddress == "tcB")
        #expect(imported.server.hosts.contains("10.0.0.2"))
        #expect(imported.token == "remote-token")
    }
}
