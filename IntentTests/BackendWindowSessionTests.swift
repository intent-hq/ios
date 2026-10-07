import Foundation
@testable import Intent
import Network
import SwiftUI
import Testing

extension BackendSessionRegistryTests {
    @Test(arguments: [WindowRetargetRoute.rebindInPlace, .openTargetWindow, .replaceWindow])
    func raisingExistingBackendDoesNotLeaveSelectionForLaterRestoration(route: WindowRetargetRoute) {
        let registry = makeRegistry()
        let stored = persistence.upsertConnection(AppCoordinatorTests.makeConnection(port: 4242))
        let backend = BackendID(stored.id)
        let window = BackendWindowSession(registry: registry, persistence: persistence)
        window.bind(to: backend)
        window.prepareForSelection(to: backend, route: route)
        window.release()

        let restored = AppCoordinator(
            workspaceStore: WorkspaceStore(forTesting: true),
            connection: FakeConnectionManager(),
            backendID: backend,
            persistence: persistence,
            sessionRegistry: registry,
            syncedRegistry: AppCoordinatorTests.syncedRegistry(payloads: [])
        )
        restored.onLoadComplete()
        #expect(restored.connectingStartedByLaunch)
    }

    @Test func sceneNetworkReportsRemainLiveAcrossInactiveAndForegroundRestart() throws {
        let factory = NetworkAvailabilityTests.MonitorFactory()
        let availability = NetworkAvailability(makeMonitor: factory.make)
        let window = BackendWindowSession(registry: makeRegistry(), networkAvailability: availability)
        defer { window.stopNetworkObservation() }
        window.updateNetworkObservation(for: .active)
        let original = try #require(factory.monitors.first)
        original.report(.satisfied)

        // Control Center makes the scene inactive, not necessarily backgrounded.
        window.updateNetworkObservation(for: .inactive)
        original.report(.unsatisfied, reason: .notAvailable)
        #expect(availability.status == .unsatisfied(.notAvailable))
        window.updateNetworkObservation(for: .active)
        #expect(factory.monitors.count == 1)
        #expect(original.cancelCount == 0)
        #expect(ConnectionNetworkMessage(status: availability.status).isUnavailable)

        window.updateNetworkObservation(for: .background)
        #expect(original.cancelCount == 1)
        #expect(availability.status == .unknown)
        window.updateNetworkObservation(for: .inactive)
        window.updateNetworkObservation(for: .active)
        let current = try #require(factory.monitors.last)
        #expect(current !== original)
        current.report(.unsatisfied, reason: .notAvailable)
        original.report(.satisfied)
        #expect(availability.status == .unsatisfied(.notAvailable))
        current.report(.satisfied)
        #expect(availability.status == .satisfied)
        #expect(!ConnectionNetworkMessage(status: availability.status).isUnavailable)
    }

    @Test func sceneNetworkLeaseSurvivesSessionChangesAndInactive() throws {
        let factory = NetworkAvailabilityTests.MonitorFactory()
        let availability = NetworkAvailability(makeMonitor: factory.make)
        let window = BackendWindowSession(registry: makeRegistry(), networkAvailability: availability)
        window.updateNetworkObservation(for: .inactive)
        #expect(factory.monitors.isEmpty)
        window.updateNetworkObservation(for: .active)
        let monitor = try #require(factory.monitors.first)
        monitor.report(.unsatisfied)
        let backend = BackendID(UUID())
        window.bind(to: backend)
        let session = try #require(window.session)
        let coordinator = session.makeCoordinator()
        coordinator.onRetryConnection()
        session.connection.connectionState = .reconnecting(attempt: 1)
        window.updateNetworkObservation(for: .inactive)
        window.updateNetworkObservation(for: .active)
        window.returnToSavedMachines()
        window.rebind(to: backend)
        window.release()
        #expect(availability.status == .unsatisfied(nil))
        #expect(factory.monitors.count == 1)
        #expect(monitor.cancelCount == 0)
        window.updateNetworkObservation(for: .background)
        #expect(monitor.cancelCount == 1)
        #expect(availability.status == .unknown)
        window.updateNetworkObservation(for: .active)
        #expect(factory.monitors.count == 2)
        monitor.report(.satisfied)
        #expect(availability.status == .unknown, "The retired scene callback must stay retired")
        window.stopNetworkObservation()
        #expect(factory.monitors[1].cancelCount == 1)
    }

    @Test func sceneNetworkLeasesShareMonitorAndReleaseOnTeardown() throws {
        let factory = NetworkAvailabilityTests.MonitorFactory()
        let availability = NetworkAvailability(makeMonitor: factory.make)
        let registry = makeRegistry()
        var first: BackendWindowSession? = BackendWindowSession(registry: registry, networkAvailability: availability)
        let second = BackendWindowSession(registry: registry, networkAvailability: availability)
        first?.updateNetworkObservation(for: .active)
        second.updateNetworkObservation(for: .active)
        let monitor = try #require(factory.monitors.first)
        #expect(factory.monitors.count == 1)
        first = nil
        #expect(monitor.cancelCount == 0)
        second.stopNetworkObservation()
        second.stopNetworkObservation()
        #expect(monitor.cancelCount == 1)
    }

    @Test func returnHomeReleasesOnlyTheLeavingWindow() throws {
        let registry = makeRegistry()
        let backend = BackendID(UUID())
        let otherBackend = BackendID(UUID())
        let leaving = BackendWindowSession(registry: registry)
        let sibling = BackendWindowSession(registry: registry)
        let other = BackendWindowSession(registry: registry)
        leaving.bind(to: backend)
        sibling.bind(to: backend)
        other.bind(to: otherBackend)
        defer { leaving.release(); sibling.release(); other.release() }
        let shared = try #require(leaving.session)
        let fake = try #require(shared.connection as? FakeConnectionManager)
        let otherFake = try #require(other.session?.connection as? FakeConnectionManager)
        shared.workspaceStore.publishFetchedWorkspaces([AppCoordinatorTests.makeWorkspace(id: "kept")])
        fake.connectionState = .reconnecting(attempt: 1)
        let coordinator = shared.makeCoordinator()
        let survivingCoordinator = try #require(sibling.session).makeCoordinator()
        survivingCoordinator.currentScreen = .workspaceDetail(workspaceId: "kept")
        coordinator.returnWindowToSavedMachines = leaving.returnToSavedMachines

        coordinator.onReturnToSavedMachines()

        #expect(leaving.isShowingSavedMachines)
        #expect(leaving.session?.backendID == nil)
        #expect(leaving.session !== shared)
        #expect(registry.attachmentCount(for: backend) == 1)
        #expect(sibling.session === shared)
        #expect(fake.disconnectCallCount == 0)
        #expect(fake.connectionState == .reconnecting(attempt: 1))
        #expect(shared.workspaceStore.workspaces.map(\.id) == ["kept"])
        #expect(survivingCoordinator.currentScreenDescription.contains("workspaceDetail"))
        #expect(otherFake.disconnectCallCount == 0)
        #expect(registry.attachmentCount(for: otherBackend) == 1)
        #expect(registry.removedBackendIDs.isEmpty)
    }

    @Test(arguments: [false, true])
    func returnHomeThenReselectSameBackendReattaches(hasSurvivingWindow: Bool) throws {
        let registry = makeRegistry()
        let stored = persistence.upsertConnection(AppCoordinatorTests.makeConnection(port: 4242))
        let backend = BackendID(stored.id)
        let window = BackendWindowSession(registry: registry)
        window.bind(to: backend)
        let original = try #require(window.session)
        let originalFake = try #require(original.connection as? FakeConnectionManager)
        if hasSurvivingWindow { _ = registry.attach(backend) }
        defer {
            window.release()
            if hasSurvivingWindow { registry.detach(backend) }
        }
        let coordinator = original.makeCoordinator()
        coordinator.returnWindowToSavedMachines = window.returnToSavedMachines

        coordinator.onReturnToSavedMachines()
        let pairing = try #require(window.session)
        let pairingFake = try #require(pairing.connection as? FakeConnectionManager)
        #expect(originalFake.disconnectCallCount == (hasSurvivingWindow ? 0 : 1))
        #expect(registry.attachmentCount(for: backend) == (hasSurvivingWindow ? 1 : 0))
        var selected: BackendID?
        let home = pairing.makeCoordinator(startingAtSavedMachines: true)
        #expect(home.currentScreenDescription == "pairing", "Home must skip the launch splash and automatic connection")
        #expect(home.routingState.hasLoadCompleted, "Deep links at Home must not wait for a skipped loading screen")
        #expect(home.backendID == nil)
        #expect(home.savedConnections.map(\.id) == [stored.id])
        #expect(home.pairingShowsSavedConnections)
        home.retargetWindow = { selected = $0 }
        home.onSwitchConnection(id: backend.connectionID)
        #expect(selected == backend)
        #expect(WindowRetargetRoute.route(
            currentBackendID: backend, target: backend, supportsMultipleWindows: true
        ) == .rebindInPlace)

        // The root must call rebind for the unchanged scene value, not wait
        // for onChange, which never fires when the same machine is selected.
        window.rebind(to: backend)

        let selectedSession = try #require(window.session)
        #expect(!window.isShowingSavedMachines)
        #expect(selectedSession.backendID == backend)
        #expect((selectedSession === original) == hasSurvivingWindow)
        #expect(pairingFake.disconnectCallCount == 1)
        #expect(registry.attachmentCount(for: backend) == (hasSurvivingWindow ? 2 : 1))
        let selectedCoordinator = selectedSession.makeCoordinator()
        selectedCoordinator.onConnectionSuccess()
        #expect(selectedCoordinator.currentScreenDescription == "workspaceList")
        coordinator.onConnectionSuccess()
        #expect(coordinator.currentScreenDescription == "pairing", "Old completions must remain retired after reselection")
    }

    @Test func returnHomeRemainsUnboundAfterWindowReappears() throws {
        let registry = makeRegistry()
        let backend = BackendID(UUID())
        let window = BackendWindowSession(registry: registry)
        window.bind(to: backend)
        window.returnToSavedMachines()
        let pairing = try #require(window.session)
        window.returnToSavedMachines()
        #expect(window.session === pairing, "Repeated actions must not replace Home again")

        window.release()
        window.bind(to: backend)
        defer { window.release() }

        #expect(window.isShowingSavedMachines)
        #expect(window.session?.backendID == nil)
        #expect(registry.attachmentCount(for: backend) == 0)
        #expect(registry.session(for: backend) == nil)
    }

    @Test func restoredHomeDoesNotAttachItsNativeBackend() throws {
        let registry = makeRegistry()
        let nativeBackend = BackendID(UUID())
        let restored = BackendWindowSession(registry: registry)
        // BackendWindowRoot restores its per-scene Home flag before binding
        // the native BackendID. This must never attach, even momentarily.
        restored.returnToSavedMachines()
        restored.bind(to: nativeBackend)
        defer { restored.release() }

        let home = try #require(restored.session).makeCoordinator(startingAtSavedMachines: true)
        home.onScenePhaseActive()
        #expect(home.currentScreenDescription == "pairing")
        #expect(restored.session?.backendID == nil)
        #expect(registry.liveBackendIDs.isEmpty)
    }

    @Test(arguments: [false, true])
    func differentMachineSelectionFromHomeKeepsExistingWindowPolicy(supportsMultipleWindows: Bool) throws {
        let registry = makeRegistry()
        let originalBackend = BackendID(UUID())
        let target = BackendID(UUID())
        let window = BackendWindowSession(registry: registry)
        window.bind(to: originalBackend)
        window.returnToSavedMachines()
        let home = try #require(window.session)
        let pairingConnection = try #require(home.connection as? FakeConnectionManager)
        // A new pairing can have connected over the transient Home session.
        pairingConnection.simulateConnect()
        defer { window.release() }
        let route = WindowRetargetRoute.route(
            currentBackendID: originalBackend, target: target, supportsMultipleWindows: supportsMultipleWindows
        )

        if supportsMultipleWindows {
            #expect(route == .openTargetWindow)
            window.release()
            window.bind(to: nil)
            #expect(window.session !== home)
            #expect(window.isShowingSavedMachines)
            #expect(window.session?.connection.connectionState == .disconnected)
        } else {
            #expect(route == .rebindInPlace)
            window.prepareToRebind()
            window.bind(to: target)
            #expect(window.session?.backendID == target)
            #expect(!window.isShowingSavedMachines)
        }
        #expect(pairingConnection.disconnectCallCount == 1)
        #expect(registry.attachmentCount(for: originalBackend) == 0)
    }
}
