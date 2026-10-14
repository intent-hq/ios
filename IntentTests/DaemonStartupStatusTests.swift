import Foundation
@testable import Intent
import Testing

struct DaemonStartupStatusTests {
    @Test func additiveDaemonVersionDoesNotChangeProgressOrReadiness() {
        var snapshot = ConnectionManagerTests.startupSnapshot()
        let original = DaemonStartupStatus.parse(snapshot)
        #expect(original?.phase == .indexing)
        snapshot["daemonVersion"] = "1.2.3"
        #expect(DaemonStartupStatus.parse(snapshot) == original)
        snapshot.removeValue(forKey: "daemonVersion")
        #expect(DaemonStartupStatus.parse(snapshot) == original)
    }

    @Test func phasesEstimatesAndStrictSchema() {
        for phase in ["preparing", "indexing", "finalizing", "ready", "failed"] {
            #expect(DaemonStartupStatus.parse(ConnectionManagerTests.startupSnapshot(phase: phase))?.phase.rawValue == phase)
        }
        var snapshot = ConnectionManagerTests.startupSnapshot()
        #expect(DaemonStartupStatus.parse(snapshot)?.estimatedRemainingMs == nil)
        snapshot["estimatedRemainingMs"] = 12_000
        #expect(DaemonStartupStatus.parse(snapshot)?.estimatedRemainingMs == 12_000)
        for invalid in [true, 2, 1.5, "1", NSNull()] as [Any] {
            snapshot["startupStatus"] = invalid
            #expect(DaemonStartupStatus.parse(snapshot) == nil)
        }
        snapshot = ConnectionManagerTests.startupSnapshot()
        for invalid in [-1, 1.1, true, 9_007_199_254_740_992] as [Any] {
            snapshot["progressAgeMs"] = invalid
            #expect(DaemonStartupStatus.parse(snapshot) == nil)
        }
        snapshot = ConnectionManagerTests.startupSnapshot(phase: "finalizing")
        snapshot["estimatedRemainingMs"] = 1
        #expect(DaemonStartupStatus.parse(snapshot) == nil)
        snapshot = ConnectionManagerTests.startupSnapshot()
        snapshot["progress"] = ["completedNotes": 21, "totalNotes": 20, "processedSourceBytes": 0, "totalSourceBytes": 0]
        #expect(DaemonStartupStatus.parse(snapshot) == nil)
    }
}

extension ConnectionManagerTests {
    @Test @MainActor func startupUnknownSchemaStaysGatedAndFailureIsTerminal() async throws {
        let previous = Self.enablePlaintextLoopback()
        defer { Self.restorePlaintextLoopback(previous) }
        let server = try await LoopbackWebSocketServer.start()
        let manager = ConnectionManager(persistence: .ephemeral())
        defer { manager.disconnect(); server.stop() }
        var snapshot = Self.startupSnapshot()
        snapshot["startupStatus"] = 2
        try server.setStartup(snapshot)
        let connecting = Task { try await manager.connect(hosts: ["127.0.0.1"], port: server.port, token: "owner") }
        defer { connecting.cancel() }
        try await waitUntil("generic startup UI") { manager.startupState == .starting(nil) }
        #expect(manager.currentPrincipal == nil)
        #expect(!server.methods.contains("principal.me"))
        try server.setStartup(Self.startupSnapshot(phase: "failed"))
        let result = await connecting.result
        if case .failure(DaemonStartupError.failed) = result {} else { Issue.record("Expected terminal startup failure") }
        #expect(manager.startupState == .failed)
        #expect(server.acceptedCount == 1)
        #expect(manager.connectionState != .connected)
    }

    @Test @MainActor func startupAttemptsAndBackendSessionsStayIndependent() async throws {
        let previous = Self.enablePlaintextLoopback()
        defer { Self.restorePlaintextLoopback(previous) }
        let server = try await LoopbackWebSocketServer.start()
        let otherServer = try await LoopbackWebSocketServer.start()
        let manager = ConnectionManager(persistence: .ephemeral())
        let other = ConnectionManager(persistence: .ephemeral())
        defer { manager.disconnect(); other.disconnect(); server.stop(); otherServer.stop() }
        var snapshot = Self.startupSnapshot()
        snapshot["estimatedRemainingMs"] = 9000
        try server.setStartup(snapshot)
        let first = Task { try await manager.connect(hosts: ["127.0.0.1"], port: server.port, token: "owner-a") }
        defer { first.cancel() }
        try await other.connect(hosts: ["127.0.0.1"], port: otherServer.port, token: "owner-b")
        try await waitUntil("first attempt") {
            if case .starting(let snapshot) = manager.startupState { return snapshot?.estimatedRemainingMs == 9000 }
            return false
        }
        #expect(other.startupState == nil)
        #expect(other.connectionState == .connected)
        snapshot = Self.startupSnapshot(attempt: "boot-b")
        snapshot["progressAgeMs"] = 40_000
        try server.setStartup(snapshot)
        try await waitUntil("new attempt clears estimate") {
            if case .starting(let snapshot) = manager.startupState { return snapshot?.attemptID == "boot-b" && snapshot?.estimatedRemainingMs == nil }
            return false
        }
        #expect(manager.connectionState != .connected)
        manager.disconnect()
        _ = await first.result
        #expect(manager.startupState == nil)
        #expect(other.connectionState == .connected)
    }

    @Test @MainActor func startupPollTimeoutClearsCurrentProgress() async throws {
        let previous = Self.enablePlaintextLoopback()
        defer { Self.restorePlaintextLoopback(previous) }
        let server = try await LoopbackWebSocketServer.start()
        let manager = ConnectionManager(persistence: .ephemeral())
        defer { manager.disconnect(); server.stop() }
        try server.setStartup(Self.startupSnapshot())
        server.holdStartupStatus()
        let connecting = Task { try await manager.connect(hosts: ["127.0.0.1"], port: server.port, token: "owner") }
        defer { connecting.cancel() }
        try await waitUntil("status timed out", timeout: .seconds(15)) { manager.startupState == .unavailable }
        #expect(manager.currentPrincipal == nil)
        #expect(Set(server.methods).isSubset(of: ["client.hello", "system.startupStatus"]))
        manager.disconnect()
        _ = await connecting.result
        #expect(manager.startupState == nil)
    }
}
