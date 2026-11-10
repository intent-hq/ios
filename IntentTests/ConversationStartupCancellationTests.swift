import Foundation
@testable import Intent
import Testing

@MainActor
struct ConversationStartupCancellationTests {
    /// Models a server that has already registered the channel when cancellation
    /// arrives. The ACK can still arrive, and cleanup has its own held completion.
    private final class LateAckConnection: FakeConnectionManager {
        let ack = TestGate()
        let release = TestGate()
        var eventRegistration = 0
        var chatStarted = false
        var cleanupStarted = false
        var cleanupCompleted = false

        override func request(_ method: String, params: [String: Any] = [:], timeout: TimeInterval = 30) async throws -> Any {
            if method == "events.subscribe" {
                eventRegistration += 1
                responseMap[method] = ["subscriptionId": "side-\(eventRegistration)"]
            }
            if method == "chat.subscribe" {
                chatStarted = true
                await ack.wait()
                return try await super.request(method, params: params, timeout: timeout)
            }
            if method == "chat.unsubscribe" {
                cleanupStarted = true
                await release.wait()
                let result = try await super.request(method, params: params, timeout: timeout)
                cleanupCompleted = true
                return result
            }
            return try await super.request(method, params: params, timeout: timeout)
        }
    }

    @Test func lateChatAckAfterCancellationIsReleasedOnceWithoutRevivingView() async throws {
        let connection = LateAckConnection()
        connection.responseMap = [
            "chat.subscribe": ["subscriptionId": "retired-chat"], "chat.unsubscribe": [:],
            "agent.get": ["agent": ["id": "parent"]], "agent.getQueue": ["queue": []],
            "agent.getSubscriptions": ["subscriptions": []],
            "events.subscribe": ["subscriptionId": "side-state"], "events.unsubscribe": [:],
            "hook.list": ["hooks": []], "prMonitor.list": ["monitors": []]
        ]
        var model: ConversationViewModel? = ConversationViewModel(
            agentId: "parent",
            workspaceId: "workspace",
            agentName: "Parent",
            connection: connection,
            uploadService: AttachmentUploadService(connection: connection),
            optionsStore: CreationOptionsStore(connectionManager: connection)
        )
        weak var store = model?.store
        weak var detailOwner = model?.agentDetails
        let load = Task { await model?.load() }
        defer { connection.ack.open(); connection.release.open(); load.cancel() }
        try await waitUntil("chat request started") { connection.chatStarted }
        model?.teardownLiveStores()
        load.cancel()
        connection.ack.open()
        try await waitUntil("orphan cleanup started") { connection.cleanupStarted }
        #expect(connection.subscriptionHandlerCount == 0)
        #expect(model?.store.eventHandlerId == nil)
        connection.release.open()
        await load.value
        #expect(connection.cleanupCompleted)
        #expect(connection.paramsForMethod("chat.unsubscribe").compactMap { $0["subscriptionId"] as? String } == ["retired-chat"])
        model = nil
        try await waitUntil("standalone owners and all local handlers released") {
            store == nil && detailOwner == nil && connection.eventHandlerCount == 0
        }
        #expect(connection.subscriptionHandlerCount == 0)
    }

    @Test func cancellingSnapshotWaiterResumesImmediatelyWithoutWaitingForTimeout() async throws {
        let connection = FakeConnectionManager()
        let transcript = ConversationLiveTranscript(connectionManager: connection)
        transcript.snapshotTimeout = .seconds(30)
        transcript.snapshotPending = true

        let waiter = Task { await transcript.awaitSnapshot() }
        try await waitUntil("waiter parked") { transcript.snapshotWaiters.count == 1 }

        waiter.cancel()
        await waiter.value
        #expect(transcript.snapshotWaiters.isEmpty, "Cancelled awaitSnapshot caller must remove and resume its continuation immediately")
    }
}
