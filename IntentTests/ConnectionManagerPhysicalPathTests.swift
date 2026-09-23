import Foundation
@testable import Intent
import Network
import Testing

extension ConnectionManagerTests {
    @Test(arguments: [NWInterface.InterfaceType.wifi, .cellular, .wiredEthernet, .loopback, .other])
    func pathClassificationUsesInterfaceType(type: NWInterface.InterfaceType) {
        // Deliberately misleading names: classification must use metadata, not prefixes.
        let path = NetworkPathSnapshot(
            isSatisfied: true,
            interfaces: [("utun-physical", type), ("en-virtual", .other), ("pdp-loopback", .loopback)]
        )
        let isPhysical = type == .wifi || type == .cellular || type == .wiredEthernet
        #expect(path.isOnPhysicalInterface == isPhysical)
        #expect(path.physicalInterfaces == (isPhysical ? ["utun-physical"] : []))
        #expect(path.primaryInterface == "utun-physical")
        #expect(path.availableInterfaces == ["utun-physical", "en-virtual", "pdp-loopback"])
    }

    @Test func physicalMembersPreservePreferenceUnderVirtualPrimary() {
        let path = NetworkPathSnapshot(
            isSatisfied: true,
            interfaces: [("vpn", .other), ("radio-b", .cellular), ("radio-a", .wifi), ("cable", .wiredEthernet)]
        )
        #expect(!path.isOnPhysicalInterface)
        #expect(path.physicalInterfaces == ["radio-b", "radio-a", "cable"])
        #expect(Self.deadPath.physicalInterfaces.isEmpty)
        #expect(!Self.deadPath.isOnPhysicalInterface)
    }

    @Test(arguments: [false, true], [false, true])
    @MainActor func physicalHandoverUnderVirtualPrimaryReconnectsImmediately(
        loopbackTunnel: Bool, toCellular: Bool
    ) async throws {
        let previous = Self.enablePlaintextLoopback()
        defer { Self.restorePlaintextLoopback(previous) }
        let manager = ConnectionManager()
        let monitors = FakePathMonitorFactory()
        let server = try await RecoveryWebSocketServer.start()
        let before = Self.virtualPath(overCellular: !toCellular)
        let after = Self.virtualPath(overCellular: toCellular)
        manager.makePathMonitor = { monitors.make() }
        if !loopbackTunnel { manager.readSocketPath = { _ in Self.endpointObservation(before) } }
        manager.tunnelDialer = PathTunnelDialer(localPort: server.port)
        manager.heartbeatClock = ManualHeartbeatClock()
        defer { server.stop() }
        defer { manager.disconnect() }
        try await manager.connect(
            hosts: loopbackTunnel ? [] : ["127.0.0.1"],
            port: server.port,
            token: "token",
            tcAddress: loopbackTunnel ? "synthetic-tunnel" : nil
        )
        let monitor = try #require(monitors.monitors.last)
        let originalSocket = try #require(manager.socket)
        let originalTunnel = manager.activeTunnel as? PathTunnelSession
        #expect((originalTunnel != nil) == loopbackTunnel)
        #expect(manager.socketInterface == nil)
        let disconnects = DisconnectCounter(manager)
        monitor.report(before)
        #expect(try await manager.request("system.status") is [String: Any])
        #expect(manager.socket === originalSocket)
        monitor.report(after)
        if !loopbackTunnel {
            #expect(manager.connectionState == .connected)
            // A system VPN's general underlay change is not endpoint loss by itself.
            manager.socketPathObservation?.viabilityChanged(false)
            try await Self.settle { disconnects.count == 1 }
        }
        #expect(Self.isReconnecting(manager.connectionState))
        #expect(disconnects.count == 1)
        #expect(monitor.cancelCount == 1)
        try await Self.settle { manager.connectionState == .connected }
        #expect(manager.socket !== originalSocket)
        #expect(monitors.monitors.count == 2)
        if let originalTunnel { #expect(await originalTunnel.isClosed) }
        let replacement = try #require(monitors.monitors.last)
        replacement.report(after)
        monitor.report(before)
        monitor.report(Self.deadPath)
        #expect(manager.connectionState == .connected)
        #expect(disconnects.count == 1)
        #expect(try await manager.request("system.status") is [String: Any])
        #expect(server.pingsReceived == 0)
    }
}

extension ConnectionManagerTests {
    @Test(arguments: [false, true])
    @MainActor func socketLossAfterVirtualMetadataChangeStillReconnects(loopbackTunnel: Bool) async throws {
        let previous = Self.enablePlaintextLoopback()
        defer { Self.restorePlaintextLoopback(previous) }
        let manager = ConnectionManager()
        let monitors = FakePathMonitorFactory()
        let server = try await RecoveryWebSocketServer.start()
        manager.makePathMonitor = { monitors.make() }
        if !loopbackTunnel {
            manager.readSocketPath = { _ in Self.endpointObservation(Self.virtualPath(overCellular: true)) }
        }
        manager.tunnelDialer = PathTunnelDialer(localPort: server.port)
        manager.heartbeatClock = ManualHeartbeatClock()
        defer {
            manager.disconnect()
            server.stop()
        }
        try await manager.connect(
            hosts: loopbackTunnel ? [] : ["127.0.0.1"],
            port: server.port,
            token: "token",
            tcAddress: loopbackTunnel ? "synthetic-tunnel" : nil
        )
        let monitor = try #require(monitors.monitors.last)
        let originalSocket = try #require(manager.socket)
        let originalTunnel = manager.activeTunnel as? PathTunnelSession
        #expect((originalTunnel != nil) == loopbackTunnel)
        let disconnects = DisconnectCounter(manager)
        monitor.report(Self.virtualPath(overCellular: true))
        monitor.report(Self.cellularPath)
        #expect(manager.connectionState == .connected)
        #expect(disconnects.count == .zero)
        #expect(try await manager.request("system.status") is [String: Any])
        #expect(manager.socket === originalSocket)
        try await Self.settle {
            manager.globalSubscriptionState == .subscribed
                && server.requestCount(method: "system.status") == 2
                && manager.pendingRequests.isEmpty
        }
        server.dropClients()
        try await Self.settle { disconnects.count == 1 && manager.connectionState == .connected }
        #expect(manager.socket !== originalSocket)
        #expect(monitor.cancelCount == 1)
        #expect(monitors.monitors.count == 2)
        if let originalTunnel { #expect(await originalTunnel.isClosed) }
        #expect(server.pingsReceived == 0)
        #expect(try await manager.request("system.status") is [String: Any])
    }

    private static func virtualPath(overCellular: Bool) -> NetworkPathSnapshot {
        NetworkPathSnapshot(
            isSatisfied: true,
            interfaces: [("utun3", .other), overCellular ? ("pdp_ip0", .cellular) : ("en0", .wifi)]
        )
    }
}

extension ConnectionManagerTests {
    private static let endpointReportCycles = 2
    private static let endpointRecoverySeconds = 6
    private static let endpointRecoveryTimeout: Duration = .seconds(endpointRecoverySeconds)

    @Test(arguments: [false, true])
    @MainActor func servingEndpointAbsentFromFirstGeneralReportStaysConnected(afterReconnect: Bool) async throws {
        let previous = Self.enablePlaintextLoopback()
        defer { Self.restorePlaintextLoopback(previous) }
        let manager = ConnectionManager()
        let monitors = FakePathMonitorFactory()
        let server = try await RecoveryWebSocketServer.start()
        // A synthetic endpoint-specific physical path; no claim about the phone's
        // actual interface type/name. Real RPCs establish that the socket serves.
        let endpointPath = NetworkPathSnapshot(
            isSatisfied: true, interfaces: [("endpoint-only", .wiredEthernet)]
        )
        let generalPath = NetworkPathSnapshot(
            isSatisfied: true, interfaces: [("general-radio", .cellular), ("general-vpn", .other)]
        )
        manager.readSocketPath = { _ in Self.endpointObservation(endpointPath) }
        manager.makePathMonitor = { monitors.make() }
        manager.heartbeatClock = ManualHeartbeatClock()
        defer {
            manager.disconnect()
            server.stop()
        }
        try await manager.connect(hosts: ["127.0.0.1"], port: server.port, token: "token")
        let disconnects = DisconnectCounter(manager)
        if afterReconnect {
            #expect(try await manager.request("system.status") is [String: Any])
            try await Self.settle { manager.globalSubscriptionState == .subscribed && manager.pendingRequests.isEmpty }
            server.dropClients()
            try await Self.settle { disconnects.count == 1 && manager.connectionState == .connected }
        }
        let servingSocket = try #require(manager.socket)
        let baselineDisconnects = disconnects.count
        let baselineMonitorCount = monitors.monitors.count
        #expect(manager.lastPathSnapshot == nil)
        #expect(manager.socketInterface == endpointPath.primaryInterface)
        for _ in 0..<Self.endpointReportCycles {
            let monitor = try #require(monitors.monitors.last)
            if monitors.monitors.count > baselineMonitorCount { #expect(manager.lastPathSnapshot == nil) }
            #expect(try await manager.request("system.status") is [String: Any])
            #expect(manager.socket === servingSocket)
            monitor.report(generalPath)
            #expect(manager.connectionState == .connected, "A satisfied general report cannot disprove endpoint service")
            #expect(disconnects.count == baselineDisconnects)
            #expect(monitor.cancelCount == 0)
            // On RED, let adoption finish so the next cycle exercises its FIRST
            // general report again. A replacement RPC does not establish continuity.
            try await Self.settle(timeout: Self.endpointRecoveryTimeout) { manager.connectionState == .connected }
            #expect(try await manager.request("system.status") is [String: Any])
            #expect(manager.socket === servingSocket)
        }
        #expect(monitors.monitors.count == baselineMonitorCount)
        #expect(server.requestCount(method: "system.status") >= Self.endpointReportCycles * 2)
        #expect(server.pingsReceived == 0)
    }
}
