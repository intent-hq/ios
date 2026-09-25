import Foundation
@testable import Intent
import Security
import SwiftUI
import Testing

extension BackendSessionRegistryTests {
    private struct WindowNameCase {
        let status: [String: Any]
        let hosts: [String]
        let expected: String
    }

    private static let titleTestPort = 4242

    @Test func windowTitleUsesSavedNameAndExistingFallbacks() {
        let cases: [WindowNameCase] = [
            .init(status: ["prettyHostname": "Studio", "hostname": "studio.local"], hosts: ["server.local"], expected: "Studio"),
            .init(status: ["prettyHostname": "  ", "hostname": "studio.local"], hosts: ["server.local"], expected: "studio.local"),
            .init(status: [:], hosts: ["server.local"], expected: "server.local:4242"),
            .init(status: [:], hosts: [], expected: "Tunnel server")
        ]
        for testCase in cases {
            let stored = persistence.upsertConnection(StoredConnection(
                server: PairedServer(hosts: testCase.hosts, port: Self.titleTestPort, name: "Tunnel server", pairedAt: Date()),
                token: "test-token",
                displayName: ConnectionPairing.displayName(fromHostStatus: testCase.status)
            ))
            let window = BackendWindowSession(registry: makeRegistry(), persistence: persistence)
            window.bind(to: BackendID(stored.id))
            #expect(window.sceneTitle == testCase.expected)
            window.release()
        }
    }

    @Test func windowTitlesStayIsolatedWhenLastUsedAndSavedNamesChange() async throws {
        let first = saveTitleConnection(name: "First", host: "first.local")
        let second = saveTitleConnection(name: "Second", host: "second.local")
        let registry = makeRegistry()
        let firstWindow = BackendWindowSession(registry: registry, persistence: persistence)
        let secondWindow = BackendWindowSession(registry: registry, persistence: persistence)
        firstWindow.bind(to: BackendID(first.id))
        secondWindow.bind(to: BackendID(second.id))
        defer { firstWindow.release(); secondWindow.release() }

        persistence.setActiveConnection(id: second.id)
        #expect(firstWindow.sceneTitle == "First")
        #expect(secondWindow.sceneTitle == "Second")
        #expect(persistence.updateConnectionDisplayName(id: first.id, displayName: "Renamed first"))
        try await waitUntil("the first window to observe its saved name") {
            firstWindow.sceneTitle == "Renamed first"
        }
        #expect(secondWindow.sceneTitle == "Second")
        persistence.setActiveConnection(id: first.id)
        #expect(persistence.updateConnectionDisplayName(id: second.id, displayName: "Renamed second"))
        try await waitUntil("the second window to observe its saved name") {
            secondWindow.sceneTitle == "Renamed second"
        }
        #expect(firstWindow.sceneTitle == "Renamed first")
    }

    @Test func titleSurvivesNavigationReconnectAndSceneLifecycle() throws {
        let stored = saveTitleConnection(name: "Studio", host: "studio.local")
        let factory = NetworkAvailabilityTests.MonitorFactory()
        let window = BackendWindowSession(
            registry: makeRegistry(),
            networkAvailability: NetworkAvailability(makeMonitor: factory.make),
            persistence: persistence
        )
        let backendID = BackendID(stored.id)
        window.bind(to: backendID)
        defer { window.release(); window.stopNetworkObservation() }
        let session = try #require(window.session)
        let coordinator = session.makeCoordinator()
        coordinator.currentScreen = .workspaceDetail(workspaceId: "workspace")
        #expect(window.sceneTitle == "Studio")
        coordinator.currentScreen = .agentConversation(agentId: "agent", workspaceId: "workspace", agentName: "Agent")
        #expect(window.sceneTitle == "Studio")
        coordinator.currentScreen = .settings
        #expect(window.sceneTitle == "Studio")
        let states: [ConnectionState] = [.disconnected, .reconnecting(attempt: 1), .connected]
        let phases: [ScenePhase] = [.active, .inactive, .background, .active]
        for state in states {
            session.connection.connectionState = state
            for phase in phases {
                window.updateNetworkObservation(for: phase)
                #expect(window.sceneTitle == "Studio")
            }
        }

        window.release()
        #expect(window.sceneTitle == nil)
        window.bind(to: backendID)
        #expect(window.sceneTitle == "Studio")
        let restored = BackendWindowSession(registry: makeRegistry(), persistence: persistence)
        restored.bind(to: backendID)
        #expect(restored.sceneTitle == "Studio")
        restored.release()
    }

    @Test func cloudPublicationAndImportedNameChangesKeepWindowLabelsCurrent() async throws {
        let store = try BackendSyncTestStore()
        defer { store.cleanUp() }
        let stored = store.manager.upsertConnection(BackendSyncFixtures.local())
        let window = BackendWindowSession(registry: makeRegistry(), persistence: store.manager)
        window.bind(to: BackendID(stored.id))
        defer { window.release() }
        #expect(window.sceneTitle == "My Mac")

        store.manager.publishPendingBackends()
        #expect(try store.cloud.object()["label"] as? String == "My Mac")
        #expect(store.manager.loadConnections().first?.pendingSyncUpdatedAt == nil)
        let publicationWrites = store.cloud.writeCount

        let records = SyncedBackendConnectionMergeTests()
        let rename = records.record(label: "Desktop rename", updatedAt: 2000)
        let outcome = store.manager.mergeSyncedBackends(records: [rename])
        #expect(outcome.updatedIds == [stored.id])
        try await waitUntil("the bound window to observe an imported iCloud name") {
            window.sceneTitle == "Desktop rename"
        }
        #expect(store.cloud.writeCount == publicationWrites, "Observing the label must not republish a remote edit")

        let removal = records.record(updatedAt: 3000, deleted: true)
        #expect(store.manager.mergeSyncedBackends(records: [removal]).removedIds == [stored.id])
        try await waitUntil("an imported iCloud removal to clear the label") { window.sceneTitle == nil }
    }

    @Test func homeRebindAndRestoredHomeNeverKeepThePreviousLabel() {
        let first = saveTitleConnection(name: "First", host: "first.local")
        let second = saveTitleConnection(name: "Second", host: "second.local")
        let registry = makeRegistry()
        let window = BackendWindowSession(registry: registry, persistence: persistence)
        let sibling = BackendWindowSession(registry: registry, persistence: persistence)
        window.bind(to: BackendID(first.id))
        sibling.bind(to: BackendID(first.id))
        defer { window.release(); sibling.release() }

        window.returnToSavedMachines()
        #expect(window.sceneTitle == nil)
        #expect(sibling.sceneTitle == "First")
        window.release()
        window.bind(to: BackendID(first.id))
        #expect(window.sceneTitle == nil)
        window.rebind(to: BackendID(first.id))
        #expect(window.sceneTitle == "First")
        window.rebind(to: BackendID(second.id))
        #expect(window.sceneTitle == "Second")
        window.rebind(to: nil)
        #expect(window.sceneTitle == nil)

        let restoredHome = BackendWindowSession(registry: registry, persistence: persistence)
        restoredHome.returnToSavedMachines()
        restoredHome.bind(to: BackendID(first.id))
        #expect(restoredHome.sceneTitle == nil)
        restoredHome.release()
    }

    @Test func removalClearsOnlyTheAffectedWindowTitle() async throws {
        let first = saveTitleConnection(name: "First", host: "first.local")
        let second = saveTitleConnection(name: "Second", host: "second.local")
        let registry = makeRegistry()
        let firstWindow = BackendWindowSession(registry: registry, persistence: persistence)
        let secondWindow = BackendWindowSession(registry: registry, persistence: persistence)
        firstWindow.bind(to: BackendID(first.id))
        secondWindow.bind(to: BackendID(second.id))
        defer { firstWindow.release(); secondWindow.release() }

        registry.markBackendRemoved(BackendID(first.id))
        #expect(firstWindow.sceneTitle == nil, "Clear as soon as removal is marked, before dismissal")
        #expect(secondWindow.sceneTitle == "Second")
        #expect(persistence.deleteConnection(id: second.id))
        try await waitUntil("a saved-record deletion to clear its window title") {
            secondWindow.sceneTitle == nil
        }
        let staleRestoration = BackendWindowSession(registry: registry, persistence: persistence)
        staleRestoration.bind(to: BackendID(second.id))
        #expect(staleRestoration.sceneTitle == nil)
        staleRestoration.release()
    }

    @Test func failedNameWriteKeepsTheSavedTitleAndObservationReleasesTheWindow() async throws {
        let stored = saveTitleConnection(name: "Saved", host: "server.local")
        let storage = try #require(persistence.keychainStorage as? InMemoryKeychainStorage)
        var window: BackendWindowSession? = BackendWindowSession(registry: makeRegistry(), persistence: persistence)
        weak var weakWindow = window
        window?.bind(to: BackendID(stored.id))
        storage.setSaveFailure(true)
        #expect(!persistence.updateConnectionDisplayName(id: stored.id, displayName: "Unsaved"))
        #expect(window?.sceneTitle == "Saved")
        storage.setSaveFailure(false)
        #expect(persistence.updateConnectionDisplayName(id: stored.id, displayName: "Saved again"))
        try await waitUntil("a successful write after a failure to refresh the title") {
            window?.sceneTitle == "Saved again"
        }
        window?.release()
        window = nil
        #expect(weakWindow == nil)
    }

    @Test func inaccessibleSavedRecordKeepsLabelUntilForegroundCanReadIt() throws {
        let keychain = FakeSecItemStore()
        persistence.keychainStorage = SecItemKeychainStorage(security: keychain.securityCalls())
        let stored = saveTitleConnection(name: "Studio", host: "studio.local")
        let factory = NetworkAvailabilityTests.MonitorFactory()
        let window = BackendWindowSession(
            registry: makeRegistry(),
            networkAvailability: NetworkAvailability(makeMonitor: factory.make),
            persistence: persistence
        )
        window.bind(to: BackendID(stored.id))
        defer { window.release(); window.stopNetworkObservation() }
        window.updateNetworkObservation(for: .background)
        keychain.readFailures[persistence.keychainAccountConnections] = errSecInteractionNotAllowed
        window.updateNetworkObservation(for: .active)
        #expect(window.sceneTitle == "Studio")
        keychain.readFailures = [:]
        // Simulate a registry refresh while the app is suspended: no in-process
        // publisher event is available, so foreground must read the new name.
        var changed = stored
        changed.displayName = "Renamed while suspended"
        let data = try JSONEncoder().encode([changed])
        #expect(persistence.saveDataToKeychain(data: data, account: persistence.keychainAccountConnections))
        window.updateNetworkObservation(for: .background)
        window.updateNetworkObservation(for: .active)
        #expect(window.sceneTitle == "Renamed while suspended")
    }

    private func saveTitleConnection(name: String, host: String) -> StoredConnection {
        persistence.upsertConnection(StoredConnection(
            server: PairedServer(hosts: [host], port: Self.titleTestPort, name: "Intent", pairedAt: Date()),
            token: "test-token",
            displayName: name
        ))
    }
}
