import Foundation
@testable import Intent
import Testing

@MainActor
struct ConversationDeltaCompatibilityTests {
    @Test func requestsIncrementalSlimSnapshotWithDefaultPageBudget() async throws {
        let connection = RPCRecordingConnection()
        connection.responseMap["chat.subscribe"] = ["subscriptionId": "chat"]
        connection.responseMap["chat.unsubscribe"] = [:] as [String: Any]
        let live = ConversationLiveTranscript(connectionManager: connection)
        defer { live.reset() }
        await live.subscribe(agentId: "agent", workspaceId: "workspace")
        let params = try #require(connection.paramsForMethod("chat.subscribe").first)
        #expect(params["agentId"] as? String == "agent")
        #expect(params["deltaEncoding"] as? String == "incremental")
        #expect(params["projection"] as? String == "slim")
        #expect(params["replaceGroup"] as? String == "ios-chat-agent")
        #expect(Set(params.keys) == ["agentId", "deltaEncoding", "projection", "replaceGroup"])
        #expect(connection.traffic().methodCounts == ["chat.subscribe": 1])
    }

    @Test func knownUnsupportedFieldRetriesOnceThenKeepsFullUntilReconnect() async {
        let connection = FakeConnectionManager()
        connection.errorQueueMap["chat.subscribe"] = [unsupportedError()]
        connection.responseMap["chat.subscribe"] = ["subscriptionId": "legacy"]
        connection.responseMap["chat.unsubscribe"] = [:] as [String: Any]
        let live = ConversationLiveTranscript(connectionManager: connection)
        var surfacedErrors = 0
        live.onSubscribeError = { _ in surfacedErrors += 1 }
        defer { live.reset() }
        await live.subscribe(agentId: "agent")
        let params = connection.paramsForMethod("chat.subscribe")
        #expect(params.count == 2)
        #expect(params.first?["deltaEncoding"] as? String == "incremental")
        #expect(params.last?["deltaEncoding"] == nil)
        #expect(params.last?["projection"] as? String == "slim")
        #expect(live.chatSubscriptionId == "legacy" && surfacedErrors == 0)
        await live.subscribe(agentId: "agent")
        #expect(connection.paramsForMethod("chat.subscribe").last?["deltaEncoding"] == nil)
        live.prepareForReconnect()
        await live.subscribe(agentId: "agent")
        #expect(connection.paramsForMethod("chat.subscribe").count == 4)
        #expect(connection.paramsForMethod("chat.subscribe").last?["deltaEncoding"] as? String == "incremental")
    }

    @Test func failingCompatibilityRetrySurfacesErrorWithoutRecursiveFallback() async {
        let connection = FakeConnectionManager()
        connection.errorMap["chat.subscribe"] = unsupportedError()
        let live = ConversationLiveTranscript(connectionManager: connection)
        live.initialRetryDelay = .seconds(60)
        var surfacedErrors = 0
        live.onSubscribeError = { _ in surfacedErrors += 1 }
        defer { live.reset() }
        await live.subscribe(agentId: "agent")
        #expect(connection.paramsForMethod("chat.subscribe").count == 2)
        #expect(surfacedErrors == 1 && live.chatSubscriptionId == nil)
        // Even later retries on this connection omit the rejected field.
        await live.subscribe(agentId: "agent")
        #expect(connection.paramsForMethod("chat.subscribe").count == 3)
        #expect(connection.paramsForMethod("chat.subscribe").last?["deltaEncoding"] == nil)
        #expect(surfacedErrors == 2)
    }

    @Test func unrelatedErrorsDoNotDisableIncrementalOrRetryImmediately() async {
        let errors = [
            NSError(domain: "WebSocket", code: -32_602, userInfo: [NSLocalizedDescriptionKey: "Invalid agentId"]),
            NSError(domain: "WebSocket", code: -32_602, userInfo: [NSLocalizedDescriptionKey: "Invalid deltaEncoding value"]),
            NSError(domain: "WebSocket", code: -32_000, userInfo: [NSLocalizedDescriptionKey: "deltaEncoding not supported"]),
            NSError(domain: "WebSocket", code: -32_001, userInfo: [NSLocalizedDescriptionKey: "Unauthorized"]),
            NSError(domain: NSURLErrorDomain, code: -32_602, userInfo: [NSLocalizedDescriptionKey: "Unknown field deltaEncoding"])
        ]
        for error in errors {
            let connection = FakeConnectionManager()
            connection.errorMap["chat.subscribe"] = error
            let live = ConversationLiveTranscript(connectionManager: connection)
            live.initialRetryDelay = .seconds(60)
            var surfaced: NSError?
            live.onSubscribeError = { surfaced = $0 as NSError }
            await live.subscribe(agentId: "agent")
            #expect(connection.paramsForMethod("chat.subscribe").count == 1)
            #expect(surfaced == error)
            await live.subscribe(agentId: "agent")
            #expect(connection.paramsForMethod("chat.subscribe").count == 2)
            #expect(connection.paramsForMethod("chat.subscribe").last?["deltaEncoding"] as? String == "incremental")
            live.reset()
        }
    }

    @Test func unsupportedErrorAfterResetCannotStartCompatibilityRetry() async throws {
        let connection = FakeConnectionManager()
        connection.pendingMethods = ["chat.subscribe"]
        let live = ConversationLiveTranscript(connectionManager: connection)
        let pending = Task { await live.subscribe(agentId: "old") }
        try await connection.waitForPendingRequests("chat.subscribe")
        live.reset()
        connection.failPending("chat.subscribe", with: unsupportedError())
        await pending.value
        #expect(connection.paramsForMethod("chat.subscribe").count == 1)
        #expect(!live.chatChannelActive)
        connection.pendingMethods = []
        connection.responseMap["chat.subscribe"] = ["subscriptionId": "new"]
        connection.responseMap["chat.unsubscribe"] = [:] as [String: Any]
        await live.subscribe(agentId: "new")
        #expect(connection.paramsForMethod("chat.subscribe").last?["deltaEncoding"] as? String == "incremental")
        live.reset()
    }

    @Test func lateCompatibilityAckIsReleasedAfterReset() async throws {
        let connection = FakeConnectionManager()
        connection.pendingMethods = ["chat.subscribe"]
        connection.responseMap["chat.unsubscribe"] = [:] as [String: Any]
        let live = ConversationLiveTranscript(connectionManager: connection)
        let pending = Task { await live.subscribe(agentId: "old") }
        try await connection.waitForPendingRequests("chat.subscribe")
        connection.failPending("chat.subscribe", with: unsupportedError())
        try await connection.waitForRequests("chat.subscribe", count: 2)
        live.reset()
        connection.resolvePending("chat.subscribe", with: ["subscriptionId": "orphan"])
        await pending.value
        #expect(connection.paramsForMethod("chat.unsubscribe").first?["subscriptionId"] as? String == "orphan")
        #expect(live.chatSubscriptionId == nil && !live.chatChannelActive)
    }

    private func unsupportedError() -> NSError {
        NSError(domain: "WebSocket", code: -32_602, userInfo: [
            NSLocalizedDescriptionKey: "unknown field `deltaEncoding`, expected `agentId` (-32602)"
        ])
    }
}
