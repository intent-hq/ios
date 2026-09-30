import Foundation
@testable import Intent
import Network
import os
import Testing

extension ConnectionManagerTests {
    @Test(arguments: [false, true], [false, true])
    @MainActor func endpointLossReconnectsWithoutGeneralReport(pathLoss: Bool, beforeAdoption: Bool) async throws {
        let previous = Self.enablePlaintextLoopback()
        defer { Self.restorePlaintextLoopback(previous) }
        let manager = ConnectionManager()
        let monitors = FakePathMonitorFactory()
        let server = try await RecoveryWebSocketServer.start()
        let first = Self.endpointObservation(Self.wifiPath)
        var observations: [SocketPathObservation] = []
        manager.readSocketPath = { _ in
            let observation = observations.isEmpty ? first : Self.endpointObservation(Self.cellularPath)
            observations.append(observation)
            return observation
        }
        manager.makePathMonitor = { monitors.make() }
        manager.heartbeatClock = ManualHeartbeatClock()
        let disconnects = DisconnectCounter(manager)
        defer {
            manager.disconnect()
            server.stop()
        }
        if beforeAdoption {
            if pathLoss { first.pathChanged(Self.deadPath) } else { first.viabilityChanged(false) }
        }
        try await manager.connect(hosts: ["127.0.0.1"], port: server.port, token: "token")
        let originalSocket = try #require(manager.socket)
        let monitor = try #require(monitors.monitors.last)
        #expect(manager.lastPathSnapshot == nil)
        if !beforeAdoption {
            #expect(try await manager.request("system.status") is [String: Any])
            if pathLoss { first.pathChanged(Self.deadPath) } else { first.viabilityChanged(false) }
        }
        // No clock advance, receive failure, or general report can drive this recovery.
        try await Self.settle { disconnects.count == 1 && manager.connectionState == .connected }
        #expect(manager.socket !== originalSocket)
        #expect(monitor.cancelCount == 1)
        #expect(monitors.monitors.count == 2)
        #expect(observations.count == 2)
        first.pathChanged(Self.deadPath)
        first.viabilityChanged(false)
        monitor.report(Self.deadPath)
        #expect(try await manager.request("system.status") is [String: Any])
        try await expectNever("retired endpoint callbacks disconnecting the replacement") { disconnects.count != 1 }
        #expect(server.pingsReceived == 0)
        manager.disconnect()
        observations.last?.pathChanged(Self.deadPath)
        observations.last?.viabilityChanged(false)
        try await expectNever("endpoint callbacks reconnecting after Home") { manager.connectionState != .disconnected }
    }

    @Test(arguments: [false, true])
    @MainActor func servingEndpointSurvivesUnsatisfiedGeneralPath(systemVPN: Bool) async throws {
        let previous = Self.enablePlaintextLoopback()
        defer { Self.restorePlaintextLoopback(previous) }
        let manager = ConnectionManager()
        let monitors = FakePathMonitorFactory()
        let server = try await RecoveryWebSocketServer.start()
        let endpoint = NetworkPathSnapshot(
            isSatisfied: true, interfaces: [("endpoint-only", systemVPN ? .other : .wiredEthernet)]
        )
        manager.readSocketPath = { _ in Self.endpointObservation(endpoint) }
        manager.makePathMonitor = { monitors.make() }
        manager.heartbeatClock = ManualHeartbeatClock()
        let advisoryMonitor = FakePathMonitor()
        let availability = NetworkAvailability { advisoryMonitor }
        let lease = availability.acquire()
        let store = WorkspaceStore(forTesting: true)
        let coordinator = AppCoordinator(workspaceStore: store, connection: manager)
        coordinator.currentScreen = .connecting
        defer {
            lease.cancel()
            manager.disconnect()
            server.stop()
        }
        try await manager.connect(hosts: ["127.0.0.1"], port: server.port, token: "token")
        store.publishFetchedWorkspaces([])
        coordinator.onInitialWorkspaceLoadComplete(attemptID: coordinator.connectionAttemptId)
        #expect(coordinator.lifecycleState.hasEnteredRemoteUI)
        let socket = try #require(manager.socket)
        let monitor = try #require(monitors.monitors.last)
        let disconnects = DisconnectCounter(manager)
        for report in [Self.deadPath, Self.cellularPath, Self.deadPath] {
            advisoryMonitor.report(report)
            monitor.report(report)
            #expect(try await manager.request("system.status") is [String: Any])
            #expect(manager.socket === socket)
            #expect(manager.connectionState == .connected)
            #expect(disconnects.count == .zero)
            #expect(monitor.cancelCount == 0)
            #expect(!coordinator.showsConnectionLossOverlay, "Default-path availability must not cover a serving route")
            #expect(availability.status == NetworkAvailability.Status(report))
        }
        #expect(server.pingsReceived == 0)
        #expect(monitors.monitors.count == 1)
    }

    @Test @MainActor func queuedEndpointLossCannotAffectNewObservationOrHome() async throws {
        let previous = Self.enablePlaintextLoopback()
        defer { Self.restorePlaintextLoopback(previous) }
        let manager = ConnectionManager()
        let server = try await RecoveryWebSocketServer.start()
        manager.makePathMonitor = { FakePathMonitor() }
        manager.readSocketPath = { _ in Self.endpointObservation(Self.cellularPath) }
        manager.heartbeatClock = ManualHeartbeatClock()
        defer {
            manager.disconnect()
            server.stop()
        }
        try await manager.connect(hosts: ["127.0.0.1"], port: server.port, token: "token")
        let socket = try #require(manager.socket)
        let first = try #require(manager.socketPathObservation)
        let disconnects = DisconnectCounter(manager)
        first.pathChanged(Self.deadPath)
        first.viabilityChanged(false)
        // Retire before the queued MainActor notification runs, without a generation change.
        manager.startPathMonitor()
        manager.socketPathObservation?.pathChanged(Self.deadPath)
        manager.socketPathObservation?.viabilityChanged(false)
        manager.socketPathObservation?.pathChanged(Self.cellularPath)
        manager.socketPathObservation?.viabilityChanged(true)
        #expect(try await manager.request("system.status") is [String: Any])
        #expect(disconnects.count == .zero)
        #expect(manager.socket === socket)
        manager.socketPathObservation?.viabilityChanged(false)
        manager.disconnect()
        try await expectNever("queued endpoint loss restarting a session after Home") {
            manager.connectionState != .disconnected
        }
        #expect(server.pingsReceived == 0)
    }

    @Test @MainActor func realSocketObservationStartsReadyAndStopsOnDisconnect() async throws {
        let previous = Self.enablePlaintextLoopback()
        defer { Self.restorePlaintextLoopback(previous) }
        let server = try await RecoveryWebSocketServer.start()
        defer { server.stop() }
        let socket = try await WebSocketConnection.connect(
            host: "127.0.0.1", port: server.port, token: "token", certFingerprint: nil
        )
        let observation = socket.pathObservation
        #expect(observation.current?.path?.isSatisfied == true)
        #expect(observation.current?.isViable == true)
        await socket.disconnect()
        #expect(observation.current == nil)
        observation.pathChanged(Self.deadPath)
        observation.viabilityChanged(false)
        #expect(observation.current == nil)
    }
}

extension ConnectionManagerTests {
    @Test @MainActor func endpointLossBeforeReconnectAdoptionReplays() async throws {
        let previous = Self.enablePlaintextLoopback()
        defer { Self.restorePlaintextLoopback(previous) }
        let manager = ConnectionManager()
        let server = try await RecoveryWebSocketServer.start()
        var observations: [SocketPathObservation] = []
        manager.makePathMonitor = { FakePathMonitor() }
        manager.readSocketPath = { _ in
            let observation = Self.endpointObservation(Self.cellularPath)
            if observations.count == 1 { observation.viabilityChanged(false) }
            observations.append(observation)
            return observation
        }
        manager.heartbeatClock = ManualHeartbeatClock()
        defer { server.stop() }
        defer { manager.disconnect() }
        try await manager.connect(hosts: ["127.0.0.1"], port: server.port, token: "token")
        let disconnects = DisconnectCounter(manager)
        observations.first?.pathChanged(Self.deadPath)
        let recoveryTimeout: Duration = .seconds(6)
        try await Self.settle(timeout: recoveryTimeout) {
            disconnects.count == 2 && manager.connectionState == .connected
        }
        #expect(observations.count == 3)
        #expect(try await manager.request("system.status") is [String: Any])
        #expect(server.pingsReceived == 0)
    }

    @Test @MainActor func unadoptedSocketCannotDisconnectWinner() async throws {
        let previous = Self.enablePlaintextLoopback()
        defer { Self.restorePlaintextLoopback(previous) }
        let manager = ConnectionManager()
        let server = try await RecoveryWebSocketServer.start()
        manager.makePathMonitor = { FakePathMonitor() }
        manager.heartbeatClock = ManualHeartbeatClock()
        defer { server.stop() }
        defer { manager.disconnect() }
        try await manager.connect(hosts: ["127.0.0.1"], port: server.port, token: "token")
        let winner = try #require(manager.socket)
        let disconnects = DisconnectCounter(manager)
        let loser = try await WebSocketConnection.connect(
            host: "127.0.0.1", port: server.port, token: "token", certFingerprint: nil
        )
        loser.pathObservation.pathChanged(Self.deadPath)
        loser.pathObservation.viabilityChanged(false)
        await loser.disconnect()
        #expect(loser.pathObservation.current == nil)
        #expect(try await manager.request("system.status") is [String: Any])
        #expect(manager.socket === winner)
        #expect(manager.connectionState == .connected)
        #expect(disconnects.count == .zero)
        #expect(server.pingsReceived == 0)
    }
}

nonisolated struct SocketPathObservationTests {
    private static let readyPath = NetworkPathSnapshot(isSatisfied: true, interfaces: [("route", .cellular)])
    private static let deadPath = NetworkPathSnapshot(isSatisfied: false, interfaces: [])

    private final class CallbackOwner: Sendable {}

    @Test(arguments: [false, true]) func teardownReleasesCallbackOwner(stop: Bool) {
        let observation = SocketPathObservation()
        weak var releasedOwner: CallbackOwner?
        do {
            let owner = CallbackOwner()
            releasedOwner = owner
            observation.observe { @Sendable in withExtendedLifetime(owner) {} }
        }
        #expect(releasedOwner != nil)
        if stop { observation.stop() } else { observation.removeObserver() }
        #expect(releasedOwner == nil)
    }

    @Test func preparingSignalsDoNotBecomeEstablishedLoss() async {
        let observation = SocketPathObservation()
        let calls = OSAllocatedUnfairLock(initialState: 0)
        observation.observe { @Sendable in calls.withLock { $0 += 1 } }
        await Task.detached {
            observation.pathChanged(Self.deadPath)
            observation.viabilityChanged(false)
        }.value
        #expect(observation.current == nil)
        #expect(calls.withLock { $0 } == 0)
        observation.ready(path: Self.readyPath)
        #expect(observation.current?.isLost == false)
        #expect(calls.withLock { $0 } == 1)
        observation.removeObserver()
    }

    @Test func latestEstablishedEvidenceReplaysOffMainAndUnsubscribes() async {
        let observation = SocketPathObservation()
        let calls = OSAllocatedUnfairLock(initialState: 0)
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async { @Sendable in
                #expect(!Thread.isMainThread)
                observation.ready(path: Self.readyPath)
                observation.pathChanged(Self.deadPath)
                observation.viabilityChanged(false)
                continuation.resume()
            }
        }
        observation.observe { @Sendable in calls.withLock { $0 += 1 } }
        #expect(calls.withLock { $0 } == 1)
        #expect(observation.current?.isLost == true)
        observation.pathChanged(Self.readyPath)
        #expect(observation.current?.isLost == true)
        observation.viabilityChanged(true)
        #expect(observation.current?.isLost == false)
        let priorCalls = calls.withLock { $0 }
        observation.removeObserver()
        observation.viabilityChanged(false)
        #expect(calls.withLock { $0 } == priorCalls)
        #expect(observation.current?.isLost == true)
    }

    @Test func cancelledCandidateCannotReplayOrRestart() {
        let observation = SocketPathObservation()
        observation.ready(path: Self.readyPath)
        observation.viabilityChanged(false)
        observation.stop()
        observation.observe { @Sendable in Issue.record("A cancelled candidate must not notify an adopter") }
        observation.ready(path: Self.readyPath)
        observation.pathChanged(Self.deadPath)
        observation.viabilityChanged(false)
        #expect(observation.current == nil)
    }
}
