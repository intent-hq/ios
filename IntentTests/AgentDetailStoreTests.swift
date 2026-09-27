import Foundation
@testable import Intent
import Testing

@MainActor
struct AgentDetailStoreTests {
    private func agent(_ metadata: [String: Any] = [:], workspace: String = "workspace") -> [String: Any] {
        ["agent": ["id": "parent", "workspaceId": workspace, "model": "model", "metadata": metadata]]
    }

    @Test func concurrentAndLateConsumersReuseOneDetail() async throws {
        let connection = FakeConnectionManager()
        connection.pendingMethods = ["agent.get"]
        let details = AgentDetailStore(connection: connection)
        let first = Task { try await details.load(agentId: "parent", workspaceId: "workspace") }
        let second = Task { try await details.load(agentId: "parent", workspaceId: "workspace") }
        defer { first.cancel(); second.cancel() }
        try await connection.waitForPendingRequests("agent.get")
        try await expectNever("a duplicate detail request") { connection.paramsForMethod("agent.get").count > 1 }
        connection.resolvePending("agent.get", with: agent())
        _ = try await first.value
        _ = try await second.value
        _ = try await details.load(agentId: "parent", workspaceId: "workspace")
        #expect(connection.paramsForMethod("agent.get").count == 1)
    }

    @Test func lateReplyPreservesNewerQuestionsSeenAndProposalResolution() async throws {
        let connection = FakeConnectionManager()
        connection.pendingMethods = ["agent.get"]
        let details = AgentDetailStore(connection: connection)
        let read = Task { try await details.load(agentId: "parent", workspaceId: "workspace") }
        defer { read.cancel() }
        try await connection.waitForPendingRequests("agent.get")
        connection.deliverEvent(method: "event", params: [
            "event": [
                "type": "agent:updated", "workspaceId": "workspace", "data": [
                    "agentId": "parent", "pendingQuestionsMessageId": "new-question",
                    "dismissedQuestionsMessageId": "new-dismissed", "lastSeenMessageId": "new-seen",
                    "pendingProposals": [], "proposalResolutions": ["proposal": "dismissed"]
                ]
            ]
        ])
        connection.resolvePending("agent.get", with: agent([
            "pendingQuestionsMessageId": "old-question", "lastSeenMessageId": "old-seen",
            "pendingProposals": [["proposalId": "proposal", "messageId": "old-message"]]
        ]))
        let result = try await read.value
        #expect(result.metadata["pendingQuestionsMessageId"] as? String == "new-question")
        #expect(result.metadata["dismissedQuestionsMessageId"] as? String == "new-dismissed")
        #expect(result.metadata["lastSeenMessageId"] as? String == "new-seen")
        let proposals = ProposalActionStore(connection: connection, agentId: "parent", workspaceId: "workspace", details: details)
        await proposals.loadIfNeeded()
        #expect(proposals.pending.isEmpty)
        #expect(proposals.resolutions["proposal"] == "dismissed")
        #expect(connection.paramsForMethod("agent.get").count == 1)
    }

    @Test func malformedAndFailedReadsRemainRetryable() async throws {
        let connection = FakeConnectionManager()
        let details = AgentDetailStore(connection: connection)
        connection.responseMap["agent.get"] = ["agent": [:]]
        await #expect(throws: (any Error).self) { try await details.load(agentId: "parent") }
        #expect(details.cached(agentId: "parent") == nil)
        connection.errorMap["agent.get"] = NSError(domain: "Test", code: 1)
        await #expect(throws: (any Error).self) { try await details.load(agentId: "parent") }
        #expect(details.cached(agentId: "parent") == nil)
        connection.errorMap.removeValue(forKey: "agent.get")
        connection.responseMap["agent.get"] = agent()
        _ = try await details.load(agentId: "parent")
        #expect(connection.paramsForMethod("agent.get").count == 3)
    }

    @Test func backendAndWorkspaceIdentityStaySeparate() async throws {
        let first = FakeConnectionManager()
        let second = FakeConnectionManager()
        first.responseMap["agent.get"] = agent(["lastSeenMessageId": "first"])
        second.responseMap["agent.get"] = agent(["lastSeenMessageId": "second"], workspace: "other")
        let firstDetails = AgentDetailStore(connection: first)
        let secondDetails = AgentDetailStore(connection: second)
        _ = try await firstDetails.load(agentId: "parent", workspaceId: "workspace")
        _ = try await secondDetails.load(agentId: "parent", workspaceId: "other")
        #expect(firstDetails.cached(agentId: "parent")?.metadata["lastSeenMessageId"] as? String == "first")
        #expect(secondDetails.cached(agentId: "parent")?.metadata["lastSeenMessageId"] as? String == "second")
        await #expect(throws: AgentDetailError.identityMismatch) {
            try await secondDetails.load(agentId: "parent", workspaceId: "workspace")
        }
        // A cross-workspace child read supplies its own id, without the parent's workspace.
        let child = try await secondDetails.load(agentId: "parent")
        #expect(child.values["workspaceId"] as? String == "other")
        #expect(second.paramsForMethod("agent.get").count == 1)
    }

    @Test func invalidationBurstHasOneTrailingRead() async throws {
        let connection = FakeConnectionManager()
        connection.pendingMethods = ["agent.get"]
        let details = AgentDetailStore(connection: connection)
        let read = Task { try await details.load(agentId: "parent") }
        defer { read.cancel() }
        try await connection.waitForPendingRequests("agent.get")
        for _ in 0..<10 { details.invalidate(agentId: "parent") }
        connection.resolvePending("agent.get", with: agent(["lastSeenMessageId": "stale"]))
        try await connection.waitForPendingRequests("agent.get")
        #expect(connection.paramsForMethod("agent.get").count == 2)
        connection.resolvePending("agent.get", with: agent(["lastSeenMessageId": "current"]))
        let result = try await read.value
        #expect(result.metadata["lastSeenMessageId"] as? String == "current")
        _ = try await details.load(agentId: "parent")
        #expect(connection.paramsForMethod("agent.get").count == 2)
    }

    @Test func reconnectInvalidatesButRepeatedConnectedDoesNot() async throws {
        let connection = FakeConnectionManager()
        connection.simulateConnect()
        connection.responseMap["agent.get"] = agent()
        let details = AgentDetailStore(connection: connection)
        _ = try await details.load(agentId: "parent")
        connection.simulateConnect()
        _ = try await details.load(agentId: "parent")
        #expect(connection.paramsForMethod("agent.get").count == 1)
        connection.simulateDisconnect()
        connection.simulateConnect()
        _ = try await details.load(agentId: "parent")
        #expect(connection.paramsForMethod("agent.get").count == 2)
    }

    @Test func lastActivationReleaseMakesNextEntryFresh() async throws {
        let connection = FakeConnectionManager()
        connection.responseMap["agent.get"] = agent()
        let details = AgentDetailStore(connection: connection)
        // A route-validation result is reusable by the first activation.
        _ = try await details.load(agentId: "parent", workspaceId: "workspace")
        let first = details.retain(agentId: "parent")
        let second = details.retain(agentId: "parent")
        _ = try await details.load(agentId: "parent")
        details.release(agentId: "parent", consumer: first)
        _ = try await details.load(agentId: "parent")
        #expect(connection.paramsForMethod("agent.get").count == 1)
        details.release(agentId: "parent", consumer: second)
        _ = details.retain(agentId: "parent")
        _ = try await details.load(agentId: "parent")
        #expect(connection.paramsForMethod("agent.get").count == 2)
    }

    @Test func explicitRefreshAndFailureKeepLastGoodDetailWithoutClaimingFreshness() async throws {
        let connection = FakeConnectionManager()
        let details = AgentDetailStore(connection: connection)
        connection.responseMap["agent.get"] = agent(["lastSeenMessageId": "first"])
        _ = try await details.load(agentId: "parent")
        connection.errorMap["agent.get"] = NSError(domain: "Test", code: 1)
        await #expect(throws: (any Error).self) { try await details.load(agentId: "parent", refresh: true) }
        #expect(details.cached(agentId: "parent")?.metadata["lastSeenMessageId"] as? String == "first")
        connection.errorMap.removeValue(forKey: "agent.get")
        connection.responseMap["agent.get"] = agent(["lastSeenMessageId": "second"])
        let retried = try await details.load(agentId: "parent")
        #expect(retried.metadata["lastSeenMessageId"] as? String == "second")
        #expect(connection.paramsForMethod("agent.get").count == 3)
    }

    @Test func lastReleaseDoesNotStartAnOrphanedTrailingRead() async throws {
        let connection = FakeConnectionManager()
        connection.pendingMethods = ["agent.get"]
        let details = AgentDetailStore(connection: connection)
        let consumer = details.retain(agentId: "parent")
        let read = Task { try await details.load(agentId: "parent") }
        defer { read.cancel() }
        try await connection.waitForPendingRequests("agent.get")
        details.release(agentId: "parent", consumer: consumer)
        connection.resolvePending("agent.get", with: agent())
        _ = try await read.value
        #expect(connection.paramsForMethod("agent.get").count == 1)
        // A later route validation still seeds its following activation.
        connection.pendingMethods = []
        connection.responseMap["agent.get"] = agent()
        _ = try await details.load(agentId: "parent", workspaceId: "workspace")
        _ = details.retain(agentId: "parent")
        _ = try await details.load(agentId: "parent", workspaceId: "workspace")
        #expect(connection.paramsForMethod("agent.get").count == 2)
    }

    @Test func wrongWorkspaceEventCannotPatchAnInflightDetail() async throws {
        let connection = FakeConnectionManager()
        connection.pendingMethods = ["agent.get"]
        let details = AgentDetailStore(connection: connection)
        let read = Task { try await details.load(agentId: "parent", workspaceId: "workspace") }
        defer { read.cancel() }
        try await connection.waitForPendingRequests("agent.get")
        connection.deliverEvent(method: "events.event", params: [
            "event": ["type": "agent:updated", "workspaceId": "other", "data": ["agentId": "parent", "lastSeenMessageId": "wrong"]]
        ])
        connection.resolvePending("agent.get", with: agent(["lastSeenMessageId": "right"]))
        let detail = try await read.value
        #expect(detail.metadata["lastSeenMessageId"] as? String == "right")
    }

    @Test func incompleteEventsShareOneReconciliationForActiveConsumers() async throws {
        let connection = FakeConnectionManager()
        let details = AgentDetailStore(connection: connection)
        _ = details.retain(agentId: "parent")
        connection.responseMap["agent.get"] = agent()
        _ = try await details.load(agentId: "parent")
        connection.pendingMethods = ["agent.get"]
        for _ in 0..<10 {
            connection.deliverEvent(method: "events.event", params: ["event": ["type": "agent:updated", "data": ["agentId": "parent"]]])
        }
        try await connection.waitForPendingRequests("agent.get")
        #expect(connection.paramsForMethod("agent.get").count == 2)
        connection.resolvePending("agent.get", with: agent(["proposalResolutions": ["proposal": "applied"]]))
        let proposals = ProposalActionStore(connection: connection, agentId: "parent", workspaceId: "workspace", details: details)
        await proposals.loadIfNeeded()
        #expect(proposals.resolutions["proposal"] == "applied")
        #expect(connection.paramsForMethod("agent.get").count == 2)
    }

    @Test func cancellingOneConsumerDoesNotCancelTheSharedRead() async throws {
        let connection = FakeConnectionManager()
        connection.pendingMethods = ["agent.get"]
        let details = AgentDetailStore(connection: connection)
        let first = Task { try await details.load(agentId: "parent") }
        let second = Task { try await details.load(agentId: "parent") }
        defer { first.cancel(); second.cancel() }
        try await connection.waitForPendingRequests("agent.get")
        first.cancel()
        connection.resolvePending("agent.get", with: agent())
        await #expect(throws: CancellationError.self) { try await first.value }
        _ = try await second.value
        #expect(connection.paramsForMethod("agent.get").count == 1)
    }

    @Test func priorConnectionFailureIsSuperseded() async throws {
        let connection = FakeConnectionManager()
        connection.simulateConnect()
        connection.pendingMethods = ["agent.get"]
        let details = AgentDetailStore(connection: connection)
        let read = Task { try await details.load(agentId: "parent") }
        defer { read.cancel() }
        try await connection.waitForPendingRequests("agent.get")
        connection.simulateDisconnect()
        connection.simulateConnect()
        connection.failPending("agent.get", with: NSError(domain: "WebSocket", code: -32_602))
        await #expect(throws: CancellationError.self) { try await read.value }
        #expect(details.cached(agentId: "parent") == nil)
    }

    @Test func explicitRefreshDuringReadWaitsForFreshServerReply() async throws {
        let connection = FakeConnectionManager()
        connection.pendingMethods = ["agent.get"]
        let details = AgentDetailStore(connection: connection)
        let initial = Task { try await details.load(agentId: "parent") }
        defer { initial.cancel() }
        try await connection.waitForPendingRequests("agent.get")
        var refreshStarted = false
        let refresh = Task {
            refreshStarted = true
            return try await details.load(agentId: "parent", refresh: true)
        }
        defer { refresh.cancel() }
        try await waitUntil("explicit refresh joining the old flight") { refreshStarted }
        connection.resolvePending("agent.get", with: agent(["lastSeenMessageId": "old"]))
        try await connection.waitForPendingRequests("agent.get")
        connection.resolvePending("agent.get", with: agent(["lastSeenMessageId": "new"]))
        let result = try await refresh.value
        _ = try await initial.value
        #expect(result.metadata["lastSeenMessageId"] as? String == "new")
        #expect(connection.paramsForMethod("agent.get").count == 2)
    }
}
