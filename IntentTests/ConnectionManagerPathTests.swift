import Foundation
@testable import Intent
import Network
import Testing

extension ConnectionManagerTests {
    @MainActor final class FakePathMonitor: NetworkPathMonitoring {
        private(set) var startCount = 0
        private(set) var cancelCount = 0
        private var onUpdate: (@MainActor @Sendable (NetworkPathSnapshot) -> Void)?

        func start(onUpdate: @escaping @MainActor @Sendable (NetworkPathSnapshot) -> Void) {
            startCount += 1
            self.onUpdate = onUpdate
        }

        func cancel() {
            cancelCount += 1
        }

        func report(_ snapshot: NetworkPathSnapshot) {
            onUpdate?(snapshot)
        }
    }

    @MainActor final class FakePathMonitorFactory {
        private(set) var monitors: [FakePathMonitor] = []

        func make() -> FakePathMonitor {
            let monitor = FakePathMonitor()
            monitors.append(monitor)
            return monitor
        }
    }

    static let wifiPath = NetworkPathSnapshot(isSatisfied: true, interfaces: [("en0", .wifi)])
    static let cellularPath = NetworkPathSnapshot(isSatisfied: true, interfaces: [("pdp_ip0", .cellular)])
    static let deadPath = NetworkPathSnapshot(isSatisfied: false, interfaces: [])

    nonisolated static func endpointObservation(_ path: NetworkPathSnapshot) -> SocketPathObservation {
        let observation = SocketPathObservation()
        observation.ready(path: path)
        return observation
    }

    @Test @MainActor func pathLossReconnectsImmediately() async throws {
        let previous = Self.enablePlaintextLoopback()
        defer { Self.restorePlaintextLoopback(previous) }
        let manager = ConnectionManager.shared
        let monitors = FakePathMonitorFactory()
        let server = try await RecoveryWebSocketServer.start()
        let originalFactory = manager.makePathMonitor
        manager.makePathMonitor = { monitors.make() }
        defer {
            manager.disconnect()
            manager.makePathMonitor = originalFactory
            server.stop()
        }

        let originalDialer = manager.tunnelDialer
        manager.tunnelDialer = PathTunnelDialer(localPort: server.port)
        defer { manager.tunnelDialer = originalDialer }
        try await manager.connect(hosts: [], port: server.port, token: "token", tcAddress: "synthetic-tunnel")
        let monitor = try #require(monitors.monitors.last)
        let disconnects = DisconnectCounter(manager)
        monitor.report(Self.wifiPath)
        monitor.report(Self.deadPath)
        #expect(Self.isReconnecting(manager.connectionState))
        #expect(disconnects.count == 1)
        #expect(monitor.cancelCount == 1)

        try await Self.settle { manager.connectionState == .connected }
        #expect(monitors.monitors.count == 2)
        #expect(monitors.monitors.last?.startCount == 1)
        monitor.report(Self.wifiPath)
        monitor.report(Self.deadPath)
        #expect(manager.connectionState == .connected)
        #expect(disconnects.count == 1)
    }

    @Test @MainActor func pathDeadAtFirstReportReconnectsImmediately() async throws {
        let previous = Self.enablePlaintextLoopback()
        defer { Self.restorePlaintextLoopback(previous) }
        let manager = ConnectionManager.shared
        let monitors = FakePathMonitorFactory()
        let server = try await RecoveryWebSocketServer.start()
        let originalFactory = manager.makePathMonitor
        manager.makePathMonitor = { monitors.make() }
        defer {
            manager.disconnect()
            manager.makePathMonitor = originalFactory
            server.stop()
        }

        let originalDialer = manager.tunnelDialer
        manager.tunnelDialer = PathTunnelDialer(localPort: server.port)
        defer { manager.tunnelDialer = originalDialer }
        try await manager.connect(hosts: [], port: server.port, token: "token", tcAddress: "synthetic-tunnel")
        let monitor = try #require(monitors.monitors.last)
        let disconnects = DisconnectCounter(manager)
        monitor.report(Self.deadPath)
        #expect(Self.isReconnecting(manager.connectionState))
        #expect(disconnects.count == 1)
        #expect(monitor.cancelCount == 1)
        try await Self.settle { manager.connectionState == .connected }
        let replacement = try #require(monitors.monitors.last)
        replacement.report(Self.wifiPath)
        replacement.report(Self.wifiPath)
        #expect(manager.connectionState == .connected)
        #expect(disconnects.count == 1)
    }

    @Test @MainActor func pathInterfaceChangeReconnectsImmediately() async throws {
        let previous = Self.enablePlaintextLoopback()
        defer { Self.restorePlaintextLoopback(previous) }
        let manager = ConnectionManager.shared
        let monitors = FakePathMonitorFactory()
        let server = try await RecoveryWebSocketServer.start()
        let originalFactory = manager.makePathMonitor
        manager.makePathMonitor = { monitors.make() }
        defer {
            manager.disconnect()
            manager.makePathMonitor = originalFactory
            server.stop()
        }

        let originalDialer = manager.tunnelDialer
        manager.tunnelDialer = PathTunnelDialer(localPort: server.port)
        defer { manager.tunnelDialer = originalDialer }
        try await manager.connect(hosts: [], port: server.port, token: "token", tcAddress: "synthetic-tunnel")
        let monitor = try #require(monitors.monitors.last)
        let disconnects = DisconnectCounter(manager)
        monitor.report(Self.wifiPath)
        monitor.report(Self.cellularPath)
        #expect(Self.isReconnecting(manager.connectionState))
        #expect(disconnects.count == 1)
        #expect(monitor.cancelCount == 1)
        try await Self.settle { manager.connectionState == .connected }
        #expect(manager.connectionState == .connected)
        #expect(disconnects.count == 1)
    }
}

extension ConnectionManagerTests {
    @Test @MainActor func unchangedSatisfiedPathKeepsConnection() async throws {
        let previous = Self.enablePlaintextLoopback()
        defer { Self.restorePlaintextLoopback(previous) }
        let manager = ConnectionManager.shared
        let monitors = FakePathMonitorFactory()
        let server = try await RecoveryWebSocketServer.start()
        let originalFactory = manager.makePathMonitor
        manager.makePathMonitor = { monitors.make() }
        defer {
            manager.disconnect()
            manager.makePathMonitor = originalFactory
            server.stop()
        }

        try await manager.connect(hosts: ["127.0.0.1"], port: server.port, token: "token")
        let monitor = try #require(monitors.monitors.last)
        let disconnects = DisconnectCounter(manager)
        monitor.report(Self.wifiPath)
        monitor.report(Self.wifiPath)
        try await expectNever("reconnect on a repeated identical path report") {
            manager.connectionState != .connected
                || disconnects.count != .zero
                || monitor.cancelCount != 0
        }
        #expect(try await manager.request("system.status") is [String: Any])
        manager.disconnect()
        #expect(monitor.cancelCount == 1)
        monitor.report(Self.deadPath)
        #expect(manager.connectionState == .disconnected)
    }

    @Test @MainActor func interfaceSwitchBeforeFirstReportReconnectsImmediately() async throws {
        let previous = Self.enablePlaintextLoopback()
        defer { Self.restorePlaintextLoopback(previous) }
        let manager = ConnectionManager.shared
        let monitors = FakePathMonitorFactory()
        let server = try await RecoveryWebSocketServer.start()
        let originalFactory = manager.makePathMonitor
        let originalReadSocketPath = manager.readSocketPath
        manager.makePathMonitor = { monitors.make() }
        manager.readSocketPath = { _ in Self.endpointObservation(Self.wifiPath) }
        defer {
            manager.disconnect()
            manager.makePathMonitor = originalFactory
            manager.readSocketPath = originalReadSocketPath
            server.stop()
        }

        let vpnOverWifi = NetworkPathSnapshot(
            isSatisfied: true,
            interfaces: [("utun3", .other), ("en0", .wifi)]
        )
        let vpnOverCellular = NetworkPathSnapshot(
            isSatisfied: true,
            interfaces: [("utun3", .other), ("pdp_ip0", .cellular)]
        )
        try await manager.connect(hosts: ["127.0.0.1"], port: server.port, token: "token")
        let monitor = try #require(monitors.monitors.last)
        let disconnects = DisconnectCounter(manager)
        monitor.report(Self.cellularPath)
        #expect(manager.connectionState == .connected)
        // #328 requires actual endpoint loss, not absence from a general route list.
        manager.socketPathObservation?.pathChanged(Self.deadPath)
        await Task.yield()
        try await Self.settle { disconnects.count == 1 }
        #expect(Self.isReconnecting(manager.connectionState))
        #expect(disconnects.count == 1)
        try await Self.settle { manager.connectionState == .connected }

        let replacement = try #require(monitors.monitors.last)
        replacement.report(vpnOverWifi)
        replacement.report(vpnOverWifi)
        #expect(manager.connectionState == .connected)
        replacement.report(vpnOverCellular)
        #expect(manager.connectionState == .connected)
        manager.socketPathObservation?.viabilityChanged(false)
        await Task.yield()
        try await Self.settle { disconnects.count == 2 }
        #expect(Self.isReconnecting(manager.connectionState))
        #expect(disconnects.count == 2)
        try await Self.settle(timeout: .seconds(6)) { manager.connectionState == .connected }
        #expect(monitors.monitors.count == 3)
    }

    @Test @MainActor func virtualSocketPathSeedsNoBaseline() async throws {
        let previous = Self.enablePlaintextLoopback()
        defer { Self.restorePlaintextLoopback(previous) }
        let manager = ConnectionManager.shared
        let monitors = FakePathMonitorFactory()
        let server = try await RecoveryWebSocketServer.start()
        let originalFactory = manager.makePathMonitor
        let originalReadSocketPath = manager.readSocketPath
        manager.makePathMonitor = { monitors.make() }
        manager.readSocketPath = { _ in
            Self.endpointObservation(NetworkPathSnapshot(
                isSatisfied: true,
                interfaces: [("lo0", .loopback)]
            ))
        }
        defer {
            manager.disconnect()
            manager.makePathMonitor = originalFactory
            manager.readSocketPath = originalReadSocketPath
            server.stop()
        }

        try await manager.connect(hosts: ["127.0.0.1"], port: server.port, token: "token")
        let monitor = try #require(monitors.monitors.last)
        let disconnects = DisconnectCounter(manager)
        monitor.report(Self.cellularPath)
        monitor.report(Self.cellularPath)
        try await expectNever("reconnect on a path report matching the socket's interface") {
            manager.connectionState != .connected
                || disconnects.count != .zero
                || monitor.cancelCount != 0
                || monitors.monitors.count != 1
        }
    }
}

extension ConnectionManagerTests {
    private static let pathChurnCycles = 2
    private static let pathChurnRecoverySeconds = 6
    private static let pathChurnRecoveryTimeout: Duration = .seconds(pathChurnRecoverySeconds)
    private static let loopbackPath = NetworkPathSnapshot(
        isSatisfied: true, interfaces: [("lo0", .loopback)]
    )
    private static let vpnCellularPath = cellularVPNPath(["utun3", "pdp_ip0"])

    nonisolated enum PathSocketRoute: CaseIterable {
        case cellular, virtualVPN, loopbackTunnel
    }

    private static func socketPath(for route: PathSocketRoute) -> NetworkPathSnapshot {
        switch route {
        case .cellular: cellularPath
        case .virtualVPN: vpnCellularPath
        case .loopbackTunnel: loopbackPath
        }
    }

    actor PathTunnelSession: TunnelSession {
        nonisolated let localPort: Int
        private(set) var isClosed = false

        init(localPort: Int) { self.localPort = localPort }
        func close() { isClosed = true }
    }

    // Exercise the real tunnel candidate/adoption path without contacting Tailcat:
    // the local test server stands in for its loopback forwarder.
    nonisolated struct PathTunnelDialer: TunnelDialing {
        let localPort: Int

        func open(tcAddress _: String, remotePort _: Int) async -> any TunnelSession {
            PathTunnelSession(localPort: localPort)
        }
    }

    // Model known fixture types explicitly. These are injected
    // monitor reports, not evidence of which reports a physical phone produces.
    private static func cellularVPNPath(_ interfaces: [String]) -> NetworkPathSnapshot {
        NetworkPathSnapshot(
            isSatisfied: true,
            interfaces: interfaces.map { (name: $0, type: $0 == "pdp_ip0" ? .cellular : .other) }
        )
    }

    @Test @MainActor func repeatedSatisfiedCellularReportsKeepServingSocket() async throws {
        try await Self.expectServingSocketSurvives(
            route: .cellular, before: Self.cellularPath, after: Self.cellularPath
        )
    }

    @Test @MainActor func secondaryVirtualInterfaceChurnKeepsServingSocket() async throws {
        try await Self.expectServingSocketSurvives(
            route: .cellular,
            before: Self.cellularVPNPath(["pdp_ip0", "utun3"]),
            after: Self.cellularVPNPath(["pdp_ip0", "utun4"])
        )
    }

    // A global path's preferred interface is not proof this serving socket died.
    @Test(arguments: PathSocketRoute.allCases)
    @MainActor func cellularVPNInterfaceOrderKeepsServingSocket(route: PathSocketRoute) async throws {
        try await Self.expectServingSocketSurvives(
            route: route,
            before: Self.cellularVPNPath(["pdp_ip0", "utun3"]),
            after: Self.vpnCellularPath
        )
    }

    @Test(arguments: PathSocketRoute.allCases)
    @MainActor func virtualPrimaryRenameKeepsServingSocket(route: PathSocketRoute) async throws {
        try await Self.expectServingSocketSurvives(
            route: route,
            before: Self.vpnCellularPath,
            after: Self.cellularVPNPath(["utun4", "pdp_ip0"])
        )
    }

    @Test(arguments: PathSocketRoute.allCases)
    @MainActor func virtualPrimaryRemovalKeepsServingSocket(route: PathSocketRoute) async throws {
        try await Self.expectServingSocketSurvives(
            route: route, before: Self.vpnCellularPath, after: Self.cellularPath
        )
    }

    @Test(arguments: PathSocketRoute.allCases)
    @MainActor func physicalPreferenceOrderKeepsServingSocket(route: PathSocketRoute) async throws {
        try await Self.expectServingSocketSurvives(
            route: route,
            before: NetworkPathSnapshot(
                isSatisfied: true, interfaces: [("pdp_ip0", .cellular), ("en0", .wifi), ("utun3", .other)]
            ),
            after: NetworkPathSnapshot(
                isSatisfied: true, interfaces: [("en0", .wifi), ("utun3", .other), ("pdp_ip0", .cellular)]
            )
        )
    }

    @Test @MainActor func unrelatedPhysicalInterfaceLossKeepsServingSocket() async throws {
        try await Self.expectServingSocketSurvives(
            route: .cellular,
            before: NetworkPathSnapshot(
                isSatisfied: true, interfaces: [("utun3", .other), ("en0", .wifi), ("pdp_ip0", .cellular)]
            ),
            after: Self.vpnCellularPath
        )
    }

    @MainActor private static func expectServingSocketSurvives(
        route: PathSocketRoute,
        before: NetworkPathSnapshot,
        after: NetworkPathSnapshot
    ) async throws {
        let previous = enablePlaintextLoopback()
        defer { restorePlaintextLoopback(previous) }
        let manager = ConnectionManager()
        let monitors = FakePathMonitorFactory()
        let server = try await RecoveryWebSocketServer.start()
        let socketPath = socketPath(for: route)
        manager.makePathMonitor = { monitors.make() }
        if route != .loopbackTunnel {
            manager.readSocketPath = { _ in endpointObservation(socketPath) }
        }
        manager.tunnelDialer = PathTunnelDialer(localPort: server.port)
        // Never advance: heartbeat cannot own a disconnect in this reproduction.
        manager.heartbeatClock = ManualHeartbeatClock()
        defer {
            manager.disconnect()
            server.stop()
        }
        try await manager.connect(
            hosts: route == .loopbackTunnel ? [] : ["127.0.0.1"],
            port: server.port,
            token: "token",
            tcAddress: route == .loopbackTunnel ? "synthetic-tunnel" : nil
        )
        let disconnects = DisconnectCounter(manager)
        let originalSocket = try #require(manager.socket)
        let originalTunnel = manager.activeTunnel as? PathTunnelSession
        #expect((originalTunnel != nil) == (route == .loopbackTunnel))
        #expect(manager.socketInterface == (socketPath.isOnPhysicalInterface ? socketPath.primaryInterface : nil))

        // Repeat across any replacement monitor to reproduce the UI/reconnect/UI
        // cycle, not just a single teardown. A reconnect must not hide a failure.
        for _ in 0..<pathChurnCycles {
            let monitor = try #require(monitors.monitors.last)
            monitor.report(before)
            #expect(try await manager.request("system.status") is [String: Any])
            #expect(manager.socket === originalSocket)
            monitor.report(after)
            #expect(manager.connectionState == .connected, "Satisfied interface churn must not tear down a serving socket")
            #expect(disconnects.count == .zero, "Path reports alone must not create a reconnect cycle")
            #expect(monitor.cancelCount == 0)

            // Keep collecting evidence on red: the unchanged server still answers
            // after policy-driven recovery. Identity/count assertions forbid
            // treating that replacement RPC as uninterrupted service.
            try await settle(timeout: pathChurnRecoveryTimeout) { manager.connectionState == .connected }
            #expect(try await manager.request("system.status") is [String: Any])
            #expect(manager.socket === originalSocket, "The RPC must use the original socket, not a replacement")
            if let originalTunnel {
                #expect(await !originalTunnel.isClosed, "Harmless reports must not close the serving tunnel")
            }
        }
        // Host-route refresh also issues system.status after each connection.
        #expect(server.requestCount(method: "system.status") >= pathChurnCycles * 2)
        #expect(server.pingsReceived == 0)
        #expect(monitors.monitors.count == 1)
        try await expectNever("late reconnect after harmless cellular/VPN reports") {
            manager.connectionState != .connected || disconnects.count != .zero
        }
    }

    @Test @MainActor func socketReceiveLossReconnectsWithoutPathChange() async throws {
        let previous = Self.enablePlaintextLoopback()
        defer { Self.restorePlaintextLoopback(previous) }
        let manager = ConnectionManager()
        let monitors = FakePathMonitorFactory()
        let server = try await RecoveryWebSocketServer.start()
        manager.makePathMonitor = { monitors.make() }
        manager.heartbeatClock = ManualHeartbeatClock()
        defer {
            manager.disconnect()
            server.stop()
        }
        try await manager.connect(hosts: ["127.0.0.1"], port: server.port, token: "token")
        let monitor = try #require(monitors.monitors.last)
        let originalSocket = try #require(manager.socket)
        let disconnects = DisconnectCounter(manager)
        monitor.report(Self.cellularPath)
        #expect(try await manager.request("system.status") is [String: Any])
        try await Self.settle {
            manager.globalSubscriptionState == .subscribed
                && server.requestCount(method: "system.status") == 2
                && manager.pendingRequests.isEmpty
        }
        server.dropClients()
        try await Self.settle { disconnects.count == 1 && manager.connectionState == .connected }
        #expect(manager.socket !== originalSocket)
        #expect(monitor.cancelCount == 1)
        #expect(server.pingsReceived == 0)
        #expect(try await manager.request("system.status") is [String: Any])
    }
}
