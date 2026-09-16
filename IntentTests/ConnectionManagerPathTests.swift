import Foundation
@testable import Intent
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

    static let wifiPath = NetworkPathSnapshot(isSatisfied: true, primaryInterface: "en0")
    static let cellularPath = NetworkPathSnapshot(isSatisfied: true, primaryInterface: "pdp_ip0")
    static let deadPath = NetworkPathSnapshot(isSatisfied: false, primaryInterface: nil)

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

        try await manager.connect(hosts: ["127.0.0.1"], port: server.port, token: "token")
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

        try await manager.connect(hosts: ["127.0.0.1"], port: server.port, token: "token")
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

        try await manager.connect(hosts: ["127.0.0.1"], port: server.port, token: "token")
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
        try await Task.sleep(for: .milliseconds(100))
        #expect(manager.connectionState == .connected)
        #expect(disconnects.count == .zero)
        #expect(monitor.cancelCount == 0)
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
        manager.readSocketPath = { _ in Self.wifiPath }
        defer {
            manager.disconnect()
            manager.makePathMonitor = originalFactory
            manager.readSocketPath = originalReadSocketPath
            server.stop()
        }

        let vpnOverWifi = NetworkPathSnapshot(
            isSatisfied: true,
            primaryInterface: "utun3",
            availableInterfaces: ["utun3", "en0"]
        )
        let vpnOverCellular = NetworkPathSnapshot(
            isSatisfied: true,
            primaryInterface: "utun3",
            availableInterfaces: ["utun3", "pdp_ip0"]
        )
        try await manager.connect(hosts: ["127.0.0.1"], port: server.port, token: "token")
        let monitor = try #require(monitors.monitors.last)
        let disconnects = DisconnectCounter(manager)
        monitor.report(Self.cellularPath)
        #expect(Self.isReconnecting(manager.connectionState))
        #expect(disconnects.count == 1)
        try await Self.settle { manager.connectionState == .connected }

        let replacement = try #require(monitors.monitors.last)
        replacement.report(vpnOverWifi)
        replacement.report(vpnOverWifi)
        #expect(manager.connectionState == .connected)
        replacement.report(vpnOverCellular)
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
            NetworkPathSnapshot(
                isSatisfied: true,
                primaryInterface: "lo0",
                isOnPhysicalInterface: false
            )
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
        try await Task.sleep(for: .milliseconds(100))
        #expect(manager.connectionState == .connected)
        #expect(disconnects.count == .zero)
        #expect(monitor.cancelCount == 0)
        #expect(monitors.monitors.count == 1)
    }
}
