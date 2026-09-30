import Foundation
@testable import Intent
import Testing

/// Use the production pending-response/cancellation race, inside the existing
/// recorder boundary. The sent ledger survives local callback cancellation.
@MainActor
private final class WatchedDetailTransportFixture {
    let connection = RPCRecordingConnection()
    let manager = ConnectionManager()
    var timeout: TimeInterval = 30
    private(set) var sent: [Int: String] = [:]
    private(set) var maximumOutstanding = 0
    private var nextID = 0

    init() {
        connection.suspendedResponse = { [weak self] method, params in
            guard let self, method == "agent.get", let agent = params["agentId"] as? String else { return nil }
            nextID += 1
            let id = nextID
            do {
                return try await manager.awaitResponse(id: id, timeout: timeout) {
                    self.sent[id] = agent
                    self.maximumOutstanding = max(self.maximumOutstanding, self.sent.count)
                    return nil
                }
            } catch {
                // A timeout is a terminal transport boundary. A caller's local
                // cancellation is not a server reply and must leave sent intact.
                if !(error is CancellationError) { sent[id] = nil }
                throw error
            }
        }
    }

    func replyToAll(error: Bool = false) {
        let requests = sent
        sent = [:]
        for (id, agent) in requests {
            let continuation = manager.pendingRequests.removeValue(forKey: id)
            if error {
                continuation?.resume(throwing: NSError(domain: "Remote", code: 1))
            } else {
                continuation?.resume(returning: ["agent": ["id": agent, "workspaceId": "workspace", "name": agent]])
            }
        }
    }

    func disconnect() {
        sent = [:]
        manager.failAllPending(error: "Connection closed")
        connection.simulateDisconnect()
    }
}

extension ConversationWatchedAgentsTests {
    @Test(arguments: [false, true])
    func cancelledSentReadsKeepSlotsThroughProductionResponseLifetime(resetStore: Bool) async throws {
        let fixture = WatchedDetailTransportFixture()
        let details = AgentDetailStore(connection: fixture.connection)
        let old = (0..<4).map { index in Task { try? await details.load(agentId: "old-\(index)") } }
        defer { old.forEach { $0.cancel() }; fixture.replyToAll() }
        try await waitUntil("four actual sent requests") { fixture.sent.count == 4 }
        if resetStore { details.reset() } else { old.forEach { $0.cancel() } }
        let replacement = Task { try await details.load(agentId: "replacement") }
        defer { replacement.cancel() }
        for _ in 0..<40 { await Task.yield() }
        #expect(fixture.maximumOutstanding == 4)
        #expect(fixture.manager.pendingRequests.count == 4)
        let pending = fixture.connection.traffic()
        print("Production response lifetime before replies: \(pending.summary)")
        let replacementAlreadySent = fixture.sent.values.contains("replacement")
        fixture.replyToAll()
        if !replacementAlreadySent {
            try await waitUntil("replacement sent after reply") { fixture.sent.values.contains("replacement") }
            fixture.replyToAll()
        }
        _ = try await replacement.value
        for task in old { #expect(await task.value == nil) }
        #expect(details.cached(agentId: "old-0") == nil)
        #expect(fixture.connection.traffic().pendingCount == 0)
        print("Production response lifetime after replies: \(fixture.connection.traffic().summary)")
    }

    @Test func cancellingSentCallerReturnsBeforeReplyWithoutDiscardingTransport() async throws {
        let fixture = WatchedDetailTransportFixture()
        defer { fixture.replyToAll() }
        let details = AgentDetailStore(connection: fixture.connection)
        var completed = false
        let caller = Task {
            defer { completed = true }
            return try? await details.load(agentId: "cancelled")
        }
        defer { caller.cancel() }
        try await waitUntil("sent caller") { fixture.sent.count == 1 }
        caller.cancel()
        try await waitUntil("caller cancellation independent of reply") { completed }
        #expect(await caller.value == nil)
        #expect(fixture.manager.pendingRequests.count == 1)
        #expect(fixture.connection.traffic().pendingCount == 1)
        fixture.replyToAll()
        try await waitUntil("late response retained in ledger") { fixture.connection.traffic().pendingCount == 0 }
        #expect(details.cached(agentId: "cancelled") == nil)
    }

    @Test(arguments: ["reply", "error", "timeout", "disconnect"])
    func cancelledTransportSlotsEndAtTerminalBoundary(boundary: String) async throws {
        let fixture = WatchedDetailTransportFixture()
        defer { fixture.replyToAll() }
        if boundary == "timeout" { fixture.timeout = 0.2 }
        let details = AgentDetailStore(connection: fixture.connection)
        let old = (0..<4).map { index in Task { try? await details.load(agentId: "old-\(index)") } }
        defer { old.forEach { $0.cancel() } }
        try await waitUntil("four occupied slots") { fixture.sent.count == 4 }
        old.forEach { $0.cancel() }
        fixture.timeout = 30
        if boundary == "disconnect" {
            fixture.disconnect()
            fixture.connection.simulateConnect()
        }
        let replacement = Task { try await details.load(agentId: "replacement") }
        defer { replacement.cancel() }
        if boundary == "reply" || boundary == "error" { fixture.replyToAll(error: boundary == "error") }
        try await waitUntil("replacement after terminal boundary") { fixture.sent.values.contains("replacement") }
        fixture.replyToAll()
        _ = try await replacement.value
        for task in old { #expect(await task.value == nil) }
        #expect(fixture.maximumOutstanding <= 4)
        #expect(fixture.manager.pendingRequests.isEmpty)
        #expect(fixture.connection.traffic().pendingCount == 0)
        print("Production response \(boundary) boundary: \(fixture.connection.traffic().summary)")
    }
}
