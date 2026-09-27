import Combine
import Foundation
@testable import Intent
import Testing

extension ConnectionManagerTests {
    static let subscribeMethod = "events.subscribe"

    static func isSubscriptionFailed(_ state: ConnectionManager.GlobalSubscriptionState) -> Bool {
        if case .failed = state { return true }
        return false
    }

    @Test func globalSubscriptionBackoffGrowsAndCaps() {
        #expect(ConnectionManager.globalSubscriptionBackoff(afterAttempt: 1) == .seconds(1))
        #expect(ConnectionManager.globalSubscriptionBackoff(afterAttempt: 2) == .seconds(2))
        #expect(ConnectionManager.globalSubscriptionBackoff(afterAttempt: 3) == .seconds(4))
        #expect(ConnectionManager.globalSubscriptionBackoff(afterAttempt: 4) == .seconds(8))
        #expect(ConnectionManager.globalSubscriptionBackoff(afterAttempt: 9) == .seconds(8))
        #expect(ConnectionManager.globalSubscriptionBackoff(afterAttempt: 0) == .seconds(1))
    }

    @Test @MainActor func globalSubscriptionRetriesUntilTheDaemonAccepts() async throws {
        let previous = Self.enablePlaintextLoopback()
        defer { Self.restorePlaintextLoopback(previous) }
        let diagnostics = DiagnosticStore(storage: DiagnosticTestStorage())
        let manager = ConnectionManager(diagnostics: diagnostics)
        let clock = ManualHeartbeatClock()
        let server = try await RecoveryWebSocketServer.start()
        server.failNextRequests(2, method: Self.subscribeMethod)
        let originalClock = manager.heartbeatClock
        manager.heartbeatClock = clock
        defer {
            manager.disconnect()
            manager.heartbeatClock = originalClock
            server.stop()
        }

        try await manager.connect(hosts: ["127.0.0.1"], port: server.port, token: "token")
        let disconnects = DisconnectCounter(manager)
        try await Self.settle { clock.pendingDurations.contains(.seconds(1)) }
        #expect(server.requestCount(method: Self.subscribeMethod) == 1)
        #expect(manager.globalSubscriptionState == .subscribing(attempt: 2))
        clock.advance(by: .seconds(1))
        try await Self.settle { clock.pendingDurations.contains(.seconds(2)) }
        #expect(server.requestCount(method: Self.subscribeMethod) == 2)
        #expect(manager.globalSubscriptionState == .subscribing(attempt: 3))
        clock.advance(by: .seconds(2))
        try await Self.settle { manager.globalSubscriptionState == .subscribed }
        #expect(server.requestCount(method: Self.subscribeMethod) == 3)
        #expect(clock.pendingDurations == [ConnectionManager.heartbeatInterval])
        #expect(disconnects.count == .zero)
        #expect(manager.connectionState == .connected)
        let records = try DiagnosticFixtures.records(await diagnostics.snapshot())
            .filter { $0.event.operation == .subscriptionGlobal }
        #expect(records.map(\.event.outcome) == [.retrying, .recovered])
        #expect(records.map(\.count) == [2, 1])
    }

    @Test @MainActor func globalSubscriptionExhaustionSurfacesFailureAndRetriesOnRequest() async throws {
        let previous = Self.enablePlaintextLoopback()
        defer { Self.restorePlaintextLoopback(previous) }
        let diagnostics = DiagnosticStore(storage: DiagnosticTestStorage())
        let manager = ConnectionManager(diagnostics: diagnostics)
        let clock = ManualHeartbeatClock()
        let server = try await RecoveryWebSocketServer.start()
        let maxAttempts = ConnectionManager.globalSubscriptionMaxAttempts
        server.failNextRequests(maxAttempts, method: Self.subscribeMethod)
        let originalClock = manager.heartbeatClock
        manager.heartbeatClock = clock
        defer {
            manager.disconnect()
            manager.heartbeatClock = originalClock
            server.stop()
        }

        try await manager.connect(hosts: ["127.0.0.1"], port: server.port, token: "token")
        for attempt in 1..<maxAttempts {
            let backoff = ConnectionManager.globalSubscriptionBackoff(afterAttempt: attempt)
            try await Self.settle { clock.pendingDurations.contains(backoff) }
            #expect(server.requestCount(method: Self.subscribeMethod) == attempt)
            #expect(manager.globalSubscriptionState == .subscribing(attempt: attempt + 1))
            clock.advance(by: backoff)
        }
        try await Self.settle {
            Self.isSubscriptionFailed(manager.globalSubscriptionState)
                && clock.pendingDurations == [ConnectionManager.heartbeatInterval]
        }
        #expect(
            manager.globalSubscriptionState
                == .failed(attempts: maxAttempts, lastError: "scripted failure (-32000)")
        )
        #expect(server.requestCount(method: Self.subscribeMethod) == maxAttempts)
        clock.advance(by: .seconds(1))
        try await expectNever("subscribe retry after the attempts are exhausted") {
            server.requestCount(method: Self.subscribeMethod) != maxAttempts
        }

        let sessionConnection: any SessionConnectionManaging = manager
        var readiness: [ConnectionManager.GlobalSubscriptionState] = []
        let observer = sessionConnection.globalSubscriptionPublisher.sink { readiness.append($0) }
        defer { observer.cancel() }
        #expect(readiness == [manager.globalSubscriptionState], "routing replays actual failed-feed readiness")
        sessionConnection.retryGlobalSubscription()
        try await Self.settle { manager.globalSubscriptionState == .subscribed }
        #expect(server.requestCount(method: Self.subscribeMethod) == maxAttempts + 1)
        #expect(readiness.last == .subscribed)
        #expect(readiness.contains(.subscribing(attempt: 1)))
        let records = try DiagnosticFixtures.records(await diagnostics.snapshot())
            .filter { $0.event.operation == .subscriptionGlobal }
        #expect(records.map(\.event.outcome) == [.retrying, .exhausted, .succeeded])
        #expect(records.map(\.count) == [UInt64(maxAttempts - 1), 1, 1])
    }
}

extension ConnectionManagerTests {
    @Test @MainActor func globalSubscriptionRetryIsRetiredByNewGeneration() async throws {
        let previous = Self.enablePlaintextLoopback()
        defer { Self.restorePlaintextLoopback(previous) }
        let manager = ConnectionManager.shared
        let clock = ManualHeartbeatClock()
        let serverA = try await RecoveryWebSocketServer.start()
        let serverB = try await RecoveryWebSocketServer.start()
        serverA.failNextRequests(10, method: Self.subscribeMethod)
        let originalClock = manager.heartbeatClock
        manager.heartbeatClock = clock
        defer {
            manager.disconnect()
            manager.heartbeatClock = originalClock
            serverA.stop()
            serverB.stop()
        }

        try await manager.connect(hosts: ["127.0.0.1"], port: serverA.port, token: "a")
        try await Self.settle { clock.pendingDurations.contains(.seconds(1)) }
        #expect(serverA.requestCount(method: Self.subscribeMethod) == 1)
        let retired = try #require(manager.globalSubscriptionTask)
        manager.disconnect()
        #expect(manager.globalSubscriptionState == .idle)
        #expect(manager.globalSubscriptionTask == nil)
        _ = await retired.value
        #expect(clock.pendingDurations.isEmpty)
        clock.advance(by: .seconds(30))
        try await expectNever("subscribe retry from a retired generation") {
            serverA.requestCount(method: Self.subscribeMethod) != 1
        }

        try await manager.connect(hosts: ["127.0.0.1"], port: serverB.port, token: "b")
        try await Self.settle { manager.globalSubscriptionState == .subscribed }
        #expect(serverB.requestCount(method: Self.subscribeMethod) == 1)
        #expect(serverA.requestCount(method: Self.subscribeMethod) == 1)
    }

    @Test @MainActor func globalSubscriptionRetryIsRetiredByReconnect() async throws {
        let previous = Self.enablePlaintextLoopback()
        defer { Self.restorePlaintextLoopback(previous) }
        let manager = ConnectionManager.shared
        let clock = ManualHeartbeatClock()
        let server = try await RecoveryWebSocketServer.start()
        server.failNextRequests(1, method: Self.subscribeMethod)
        let originalClock = manager.heartbeatClock
        manager.heartbeatClock = clock
        defer {
            manager.disconnect()
            manager.heartbeatClock = originalClock
            server.stop()
        }

        try await manager.connect(hosts: ["127.0.0.1"], port: server.port, token: "token")
        try await Self.settle { clock.pendingDurations.contains(.seconds(1)) }
        #expect(server.requestCount(method: Self.subscribeMethod) == 1)
        let retired = try #require(manager.globalSubscriptionTask)
        let disconnects = DisconnectCounter(manager)
        server.dropClients()
        try await Self.settle(timeout: .seconds(5)) {
            manager.connectionState == .connected
                && manager.globalSubscriptionState == .subscribed
        }
        #expect(disconnects.count == 1)
        #expect(manager.globalSubscriptionTask != retired)
        _ = await retired.value
        #expect(server.requestCount(method: Self.subscribeMethod) == 2)
        clock.advance(by: .seconds(10))
        try await expectNever("subscribe retry from the retired pre-reconnect task") {
            server.requestCount(method: Self.subscribeMethod) != 2
                || manager.globalSubscriptionState != .subscribed
        }
    }
}
