import Foundation
@testable import Intent
import Testing

extension ConnectionManagerTests {
    @Test @MainActor func startupAdmissionPollsWithoutHydratingAndRequiresFreshHello() async throws {
        let previous = Self.enablePlaintextLoopback()
        defer { Self.restorePlaintextLoopback(previous) }
        let server = try await LoopbackWebSocketServer.start()
        let manager = ConnectionManager(persistence: .ephemeral())
        defer { manager.disconnect(); server.stop() }
        try server.setStartup(Self.startupSnapshot())
        let connecting = Task {
            try await manager.connect(hosts: ["127.0.0.1"], port: server.port, token: "saved-owner")
        }
        defer { connecting.cancel() }
        try await waitUntil("startup status requested", timeout: .seconds(5)) {
            server.methods.contains("system.startupStatus")
        }
        #expect(manager.connectionState != .connected)
        #expect(manager.currentPrincipal == nil)
        #expect(Set(server.methods).isSubset(of: ["client.hello", "system.startupStatus"]))
        await #expect(throws: (any Error).self) { _ = try await manager.request("workspace.create") }
        #expect(!server.methods.contains("workspace.create"))
        server.clearStartup()
        server.dropConnections()
        try await connecting.value
        #expect(manager.connectionState == .connected)
        #expect(server.acceptedCount == 2)
        #expect(server.methods.filter { $0 == "client.hello" }.count == 2)
        #expect(server.methods.contains("principal.me"))
    }

    nonisolated static func startupSnapshot(phase: String = "indexing", attempt: String = "boot-a") -> [String: Any] {
        let elapsed = 5000
        let phaseElapsed = 4000
        let retry = 1000
        let completedNotes = 5
        let totalNotes = 20
        let processedBytes = 50
        let totalBytes = 200
        var snapshot: [String: Any] = [
            "startupStatus": 1, "attemptId": attempt, "phase": phase,
            "elapsedMs": elapsed, "phaseElapsedMs": phaseElapsed, "progressAgeMs": 0, "retryAfterMs": retry,
            "progress": ["completedNotes": completedNotes, "totalNotes": totalNotes, "processedSourceBytes": processedBytes, "totalSourceBytes": totalBytes]
        ]
        if phase == "finalizing" { snapshot["finalizingStep"] = "committing" }
        if phase == "ready" || phase == "failed" {
            snapshot.removeValue(forKey: "retryAfterMs")
            snapshot["phaseElapsedMs"] = 0
            snapshot["progressAgeMs"] = 0
        }
        if phase == "failed" {
            snapshot["failure"] = ["code": "startup-failed", "message": "Daemon startup failed. Check daemon logs."]
        }
        return snapshot
    }
}
