import Foundation
import Security
import Testing

@testable import Intent

struct PersistenceBackendSyncTests {
    @Test func unclassifiedLegacyPairingNeverPublishesOwnerCredentials() throws {
        let store = try BackendSyncTestStore()
        defer { store.cleanUp() }
        let local = BackendSyncFixtures.local()
        #expect(store.manager.savePairing(server: local.server, token: local.token))
        store.manager.publishPendingBackends()
        #expect(store.cloud.writeCount == 0)
        #expect(store.manager.activeConnection()?.principal == nil)
        #expect(store.manager.activeConnection()?.token == local.token)
    }

    @Test func equalClockRouteUpgradeUpdatesLiveCacheWithoutPublication() throws {
        let store = try BackendSyncTestStore()
        defer { store.cleanUp() }
        let oldImport = SyncedBackendConnectionMergeTests().local(hosts: ["mac.local"], syncUpdatedAt: 200)
        try store.seed([oldImport])
        store.manager.setActiveConnection(id: oldImport.id)
        try store.cloud.put(BackendSyncFixtures.remote(clock: 200))
        let live = FakeConnectionManager()
        let coordinator = AppCoordinator(
            workspaceStore: WorkspaceStore(forTesting: true),
            connection: live,
            backendID: BackendID(oldImport.id),
            persistence: store.manager,
            syncedRegistry: SyncedBackendRegistry(keychain: store.cloud, accessGroup: BackendSyncFixtures.accessGroup)
        )
        #expect(coordinator.refreshSyncedBackends()?.updatedIds == [oldImport.id])
        #expect(live.updateCachedCredentialsLog.last?.tcAddress == "tcDesktop")
        #expect(live.updateCachedCredentialsLog.last?.token == oldImport.token)
        #expect(store.manager.activeConnection()?.syncUpdatedAt == 200)
        #expect(coordinator.refreshSyncedBackends()?.changed == false)
        #expect(store.cloud.writeCount == 0)
    }

    @Test func pairingPublishesAndSecondClientImportsCredentialsAndRoutes() async throws {
        let store = try BackendSyncTestStore()
        defer { store.cleanUp() }
        let connection = FakeConnectionManager()
        connection.responseMap["host.status"] = ["prettyHostname": "Paired Mac"]
        let local = BackendSyncFixtures.local()
        try await connection.connect(hosts: local.server.hosts, port: local.server.port, token: local.token, certFingerprint: local.server.certFingerprint, tcAddress: local.server.tcAddress)
        let paired = try await ConnectionPairing.finalize(
            server: local.server,
            token: local.token,
            connection: connection,
            persistence: store.manager
        )
        // The route refresh/publication task runs independently of pairing UI.
        let maxTaskYields = 20
        for _ in 0..<maxTaskYields where store.cloud.writeCount == 0 { await Task.yield() }
        #expect(store.cloud.writeCount == 1)
        #expect(store.manager.activeConnection()?.id == paired.id)
        #expect(connection.refreshHostRoutesCallCount == 1)
        let registry = SyncedBackendRegistry(keychain: store.cloud, accessGroup: BackendSyncFixtures.accessGroup)
        guard case .available(let records) = registry.listLiveBackends() else {
            Issue.record("The second client could not read the published record")
            return
        }
        let imported = try #require(SyncedBackendConnectionMerge.merge(records: records, into: []).connections.first)
        #expect(imported.server.certFingerprint == "aa:bb")
        #expect(imported.server.hosts == ["Mac.Local"])
        #expect(imported.server.tcAddress == BackendSyncFixtures.route)
        #expect(imported.token == "local-token")
        #expect(imported.displayName == "Paired Mac")
        #expect(imported.pendingSyncUpdatedAt == nil)
        #expect(store.manager.loadConnections().first?.pendingSyncUpdatedAt == nil)
    }

    @Test func tunnelOnlyPairingRoundTripsCaseSensitiveRoute() throws {
        let store = try BackendSyncTestStore()
        defer { store.cleanUp() }
        let local = BackendSyncFixtures.local(hosts: [])
        #expect(store.manager.saveVerifiedOwnerForTesting(server: local.server, token: local.token))
        let registry = SyncedBackendRegistry(keychain: store.cloud, accessGroup: BackendSyncFixtures.accessGroup)
        guard case .available(let records) = registry.listBackends() else {
            Issue.record("Expected available registry")
            return
        }
        let imported = try #require(SyncedBackendConnectionMerge.merge(records: records, into: []).connections.first)
        #expect(imported.server.tcAddress == BackendSyncFixtures.route)
        #expect(imported.server.hosts.isEmpty)
        #expect(imported.token == local.token)
    }

    @Test func failedLocalPairingWritesNothingToSharedKeychain() async throws {
        let store = try BackendSyncTestStore()
        defer { store.cleanUp() }
        store.local.setSaveFailure(true)
        let local = BackendSyncFixtures.local()
        let connection = FakeConnectionManager()
        try await connection.connect(hosts: local.server.hosts, port: local.server.port, token: local.token, certFingerprint: local.server.certFingerprint, tcAddress: local.server.tcAddress)
        await #expect(throws: ConnectionPairing.PersistenceError.saveFailed) {
            try await ConnectionPairing.finalize(
                server: local.server,
                token: local.token,
                connection: connection,
                persistence: store.manager
            )
        }
        store.manager.publishPendingBackends()
        #expect(store.cloud.writeCount == 0)
        #expect(store.manager.loadConnections().isEmpty)
    }

    @Test func cloudFailureKeepsLocalPairingAndRetriesAfterRelaunchWithoutRestamping() throws {
        let store = try BackendSyncTestStore()
        defer { store.cleanUp() }
        store.cloud.writeFailure = errSecNotAvailable
        let local = BackendSyncFixtures.local()
        #expect(store.manager.saveVerifiedOwnerForTesting(server: local.server, token: local.token))
        let pending = try #require(store.manager.activeConnection())
        #expect(pending.token == local.token)
        #expect(pending.pendingSyncUpdatedAt == 1000)
        #expect(store.cloud.writeCount == 1)

        let relaunched = PersistenceManager(
            defaults: store.defaults,
            keychainStorage: store.local,
            backendPublisher: BackendSyncFixtures.publisher(store.cloud, clock: 9000)
        )
        store.cloud.writeFailure = nil
        relaunched.publishPendingBackends()
        #expect(try store.cloud.object()["updatedAt"] as? Double == pending.pendingSyncUpdatedAt)
        #expect(relaunched.activeConnection()?.id == pending.id)
        #expect(relaunched.activeConnection()?.pendingSyncUpdatedAt == nil)
        relaunched.publishPendingBackends()
        #expect(store.cloud.writeCount == 2)
    }

    @Test func sameMillisecondRepairRotatesTokenAndKeepsIDAcrossHostChanges() throws {
        let store = try BackendSyncTestStore()
        defer { store.cleanUp() }
        let first = BackendSyncFixtures.local()
        #expect(store.manager.saveVerifiedOwnerForTesting(server: first.server, token: first.token))
        let original = try #require(store.manager.activeConnection())
        let repaired = BackendSyncFixtures.local(hosts: ["new-host.local"], token: "rotated-token")
        #expect(store.manager.saveVerifiedOwnerForTesting(server: repaired.server, token: repaired.token))
        let current = try #require(store.manager.activeConnection())
        #expect(current.id == original.id)
        #expect(store.manager.loadConnections().count == 1)
        let originalClock = try #require(original.syncUpdatedAt)
        #expect(current.syncUpdatedAt == originalClock + 1)
        #expect(try store.cloud.object()["token"] as? String == "rotated-token")
        #expect(store.cloud.items.count == 1)
    }

    @Test func staleRetryThenForegroundAdoptsNewerSharedEdit() throws {
        let store = try BackendSyncTestStore()
        defer { store.cleanUp() }
        store.cloud.readFailure = errSecInteractionNotAllowed
        let local = BackendSyncFixtures.local()
        #expect(store.manager.saveVerifiedOwnerForTesting(server: local.server, token: local.token))
        store.cloud.readFailure = nil
        try store.cloud.put(BackendSyncFixtures.remote(clock: 3000))
        let coordinator = AppCoordinator(
            workspaceStore: WorkspaceStore(forTesting: true),
            connection: FakeConnectionManager(),
            persistence: store.manager,
            syncedRegistry: SyncedBackendRegistry(keychain: store.cloud, accessGroup: BackendSyncFixtures.accessGroup)
        )
        coordinator.onScenePhaseActive()
        #expect(store.cloud.writeCount == 0)
        #expect(store.manager.activeConnection()?.token == "remote-token")
        #expect(store.manager.activeConnection()?.pendingSyncUpdatedAt == nil)
    }

    @Test func stalePendingRetryHonorsNewerTombstone() throws {
        let store = try BackendSyncTestStore()
        defer { store.cleanUp() }
        store.cloud.readFailure = errSecInteractionNotAllowed
        let local = BackendSyncFixtures.local()
        #expect(store.manager.saveVerifiedOwnerForTesting(server: local.server, token: local.token))
        store.cloud.readFailure = nil
        let millisecondsPerSecond = 1000.0
        let clock = Date().timeIntervalSince1970 * millisecondsPerSecond
        try store.cloud.put(BackendSyncFixtures.remote(clock: clock, deleted: true))
        let coordinator = AppCoordinator(
            workspaceStore: WorkspaceStore(forTesting: true),
            connection: FakeConnectionManager(),
            persistence: store.manager,
            syncedRegistry: SyncedBackendRegistry(keychain: store.cloud, accessGroup: BackendSyncFixtures.accessGroup)
        )
        coordinator.refreshSyncedBackends()
        #expect(store.cloud.writeCount == 0)
        #expect(store.manager.loadConnections().isEmpty)
        store.manager.publishPendingBackends()
        #expect(store.cloud.writeCount == 0)
    }

    @Test func backfillUsesPairingTimeAndNeverExportsImportedRecords() throws {
        let store = try BackendSyncTestStore(clock: 9000)
        defer { store.cleanUp() }
        var local = BackendSyncFixtures.local(clock: 100)
        local.pendingSyncUpdatedAt = nil
        var imported = BackendSyncFixtures.local(hosts: ["imported.local"])
        imported.syncUpdatedAt = 200
        imported.pendingSyncUpdatedAt = nil
        try store.seed([local, imported])
        let pairedAt = try #require(store.manager.loadConnections().first?.server.pairedAt)
        let expectedClock = pairedAt.timeIntervalSince1970 * 1000
        store.manager.publishPendingBackends()
        #expect(store.cloud.writeCount == 1)
        #expect(try store.cloud.object()["updatedAt"] as? Double == expectedClock)
        #expect(store.manager.loadConnections().last == imported)
    }

    @Test func backfillCannotReviveEvenExpiredNewerRemoval() throws {
        let store = try BackendSyncTestStore(clock: 9000)
        defer { store.cleanUp() }
        var old = BackendSyncFixtures.local(clock: 100)
        old.pendingSyncUpdatedAt = nil
        try store.seed([old])
        try store.cloud.put(BackendSyncFixtures.remote(clock: 200, deleted: true))
        store.manager.publishPendingBackends()
        #expect(store.cloud.writeCount == 0)
        #expect(try store.cloud.object()["deleted"] as? Bool == true)
    }
}

extension PersistenceBackendSyncTests {
    @Test func supersededBackfillStaysRetiredAfterPurgeAndRelaunch() throws {
        let store = try BackendSyncTestStore()
        defer { store.cleanUp() }
        var old = BackendSyncFixtures.local(clock: 100)
        old.pendingSyncUpdatedAt = nil
        try store.seed([old])
        try store.cloud.put(BackendSyncFixtures.remote(clock: 200, deleted: true))
        store.manager.publishPendingBackends()
        #expect(store.cloud.writeCount == 0)
        store.cloud.items.removeAll()
        let relaunched = PersistenceManager(
            defaults: store.defaults,
            keychainStorage: store.local,
            backendPublisher: BackendSyncFixtures.publisher(store.cloud)
        )
        relaunched.publishPendingBackends()
        #expect(store.cloud.writeCount == 0)
        #expect(store.cloud.items.isEmpty)
    }

    @Test func observedRemovalSurvivesKeychainSaveFailureButAllowsDeliberateRepair() throws {
        let store = try BackendSyncTestStore()
        defer { store.cleanUp() }
        let pending = BackendSyncFixtures.local(clock: 100)
        try store.seed([pending])
        try store.cloud.put(BackendSyncFixtures.remote(clock: 200, deleted: true))
        store.local.setSaveFailure(true)
        store.manager.publishPendingBackends()
        store.cloud.items.removeAll()
        let relaunched = PersistenceManager(
            defaults: store.defaults,
            keychainStorage: store.local,
            backendPublisher: BackendSyncFixtures.publisher(store.cloud, clock: 100)
        )
        relaunched.publishPendingBackends()
        #expect(store.cloud.writeCount == 0)
        store.local.setSaveFailure(false)
        relaunched.publishPendingBackends()
        #expect(store.cloud.writeCount == 0)
        #expect(relaunched.saveVerifiedOwnerForTesting(server: pending.server, token: "deliberate-repair"))
        #expect(try store.cloud.object()["token"] as? String == "deliberate-repair")
        #expect(try store.cloud.object()["updatedAt"] as? Double == 201)
    }

    @Test func equalClockSameTokenCollisionImportsWinningRouteAndLiveCache() throws {
        let store = try BackendSyncTestStore()
        defer { store.cleanUp() }
        var pending = SyncedBackendConnectionMergeTests().local(
            hosts: ["mac.local"],
            token: "shared-token",
            syncUpdatedAt: 500,
            tcAddress: "tcOld"
        )
        pending.pendingSyncUpdatedAt = 1000
        try store.seed([pending])
        store.manager.setActiveConnection(id: pending.id)
        var remote = BackendSyncFixtures.remote(clock: 1000)
        remote["token"] = "shared-token"
        remote["tcAddress"] = "tcNew"
        try store.cloud.put(remote)
        let live = FakeConnectionManager()
        let coordinator = AppCoordinator(
            workspaceStore: WorkspaceStore(forTesting: true),
            connection: live,
            backendID: BackendID(pending.id),
            persistence: store.manager,
            syncedRegistry: SyncedBackendRegistry(keychain: store.cloud, accessGroup: BackendSyncFixtures.accessGroup)
        )
        #expect(coordinator.refreshSyncedBackends()?.updatedIds == [pending.id])
        #expect(store.cloud.writeCount == 0)
        #expect(store.manager.activeConnection()?.server.tcAddress == "tcNew")
        #expect(store.manager.activeConnection()?.displayName == "Desktop name")
        #expect(store.manager.activeConnection()?.pendingSyncUpdatedAt == nil)
        #expect(live.updateCachedCredentialsLog.last?.tcAddress == "tcNew")
        #expect(coordinator.refreshSyncedBackends()?.changed == false)
    }

    @Test func backfillSaveFailureDoesNotPublish() throws {
        let store = try BackendSyncTestStore()
        defer { store.cleanUp() }
        var old = BackendSyncFixtures.local(clock: 100)
        old.pendingSyncUpdatedAt = nil
        try store.seed([old])
        store.local.setSaveFailure(true)
        store.manager.publishPendingBackends()
        #expect(store.cloud.writeCount == 0)
        #expect(store.manager.loadConnections() == [old])
    }

    @Test func acknowledgementFailureRetriesWithoutSecondWrite() throws {
        let store = try BackendSyncTestStore()
        defer { store.cleanUp() }
        let local = BackendSyncFixtures.local()
        _ = store.manager.upsertConnection(local)
        store.cloud.beforeWrite = { store.local.setSaveFailure(true) }
        store.manager.publishPendingBackends()
        #expect(store.cloud.writeCount == 1)
        #expect(store.manager.loadConnections().first?.pendingSyncUpdatedAt != nil)
        store.local.setSaveFailure(false)
        store.manager.publishPendingBackends()
        #expect(store.cloud.writeCount == 1)
        #expect(store.manager.loadConnections().first?.pendingSyncUpdatedAt == nil)
    }

    @Test func deletingPendingPairingCancelsRetry() throws {
        let store = try BackendSyncTestStore()
        defer { store.cleanUp() }
        let local = store.manager.upsertConnection(BackendSyncFixtures.local())
        #expect(store.manager.deleteConnection(id: local.id))
        store.manager.publishPendingBackends()
        #expect(store.cloud.writeCount == 0)
    }

    @Test func defaultTestStoresDoNotInstallProductionWriter() throws {
        let store = try BackendSyncTestStore()
        defer { store.cleanUp() }
        #expect(PersistenceManager(defaults: store.defaults, keychainStorage: store.local).backendPublisher == nil)
        #expect(SyncedBackendPublisher.production() == nil)
    }
}
