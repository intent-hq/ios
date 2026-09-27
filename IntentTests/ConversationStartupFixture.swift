import Foundation
@testable import Intent
import Testing

/// Reuses one backend connection/catalog across actual view models. A second
/// panel is the warm-workspace case; today's per-view status stores still read
/// again. Future shared-store implementations should change this composition
/// seam, not fake the optimized method list in the recorder.
@MainActor
final class ConversationStartupFixture {
    static let workspaceId = "startup-workspace"
    static let parentId = "startup-parent"
    static let childId = "watched-child"
    static let messageId = "startup-message"
    let connection = RPCRecordingConnection()
    let options: CreationOptionsStore
    private(set) var viewModels: [ConversationViewModel] = []
    var parentMetadata: [String: Any] = ["lastSeenMessageId": ConversationStartupFixture.messageId]
    var watchedIds: [String] = []
    var unrelatedAgentCount = 0
    var modelId: String?
    var providerId: String?

    init() {
        connection.holdsConnectionStateDelivery = true
        connection.simulateConnect()
        connection.globalSubscriptionState = .subscribed
        options = CreationOptionsStore(connectionManager: connection)
        connection.responseMap = [
            "events.unsubscribe": [:], "chat.unsubscribe": [:],
            "agent.getQueue": ["queue": []],
            "hook.list": ["hooks": []], "prMonitor.list": ["monitors": []],
            "specialist.list": ["specialists": []], "models.list": ["models": []]
        ]
        connection.responseForRequest = { [weak self] method, params in
            self?.response(method: method, params: params)
        }
    }

    func makeViewModel(agentId: String = ConversationStartupFixture.parentId) -> ConversationViewModel {
        let viewModel = ConversationViewModel(
            agentId: agentId,
            workspaceId: Self.workspaceId,
            agentName: "Startup fixture",
            connection: connection,
            uploadService: AttachmentUploadService(connection: connection),
            optionsStore: options
        )
        viewModels.append(viewModel)
        return viewModel
    }

    func makeProposalStore(agentId: String = ConversationStartupFixture.parentId) -> ProposalActionStore {
        ProposalActionStore(connection: connection, agentId: agentId, workspaceId: Self.workspaceId)
    }

    /// A bounded negative observation lets the real receive(on:) replay run
    /// while all stores are unbound. No requests should originate from it.
    func deliverInitialConnectionBeforeBinding() async throws {
        let checkpoint = connection.checkpoint
        connection.releaseConnectionStateDelivery()
        try await expectNever("RPC from unbound connected replay") {
            !connection.traffic(since: checkpoint).requests.isEmpty
        }
    }

    func stop() {
        for viewModel in viewModels {
            viewModel.teardownLiveStores()
            viewModel.store.reset()
        }
    }

    func agent(_ id: String) -> [String: Any] {
        var row: [String: Any] = [
            "id": id, "workspaceId": Self.workspaceId, "name": "Agent \(id)",
            "status": "active", "isStreaming": false,
            "metadata": id == Self.parentId ? parentMetadata : [:]
        ]
        if id == Self.parentId {
            row["model"] = modelId
            row["provider"] = providerId
        }
        return row
    }

    func subscriptions() -> [String: Any] {
        [
            "subscriptions": watchedIds.isEmpty ? [] : [["actorIds": watchedIds]],
            "delegationGroups": [],
            "agentStatuses": Dictionary(uniqueKeysWithValues: watchedIds.map { ($0, "active") })
        ]
    }

    private func response(method: String, params: [String: Any]) -> Any? {
        switch method {
        case "agent.get":
            return ["agent": agent(params["agentId"] as? String ?? Self.parentId)]
        case "agent.getSubscriptions":
            return subscriptions()
        case "agent.list":
            let unrelated = (0..<unrelatedAgentCount).map { agent("unrelated-\($0)") }
            return ["agents": [agent(Self.parentId)] + watchedIds.map(agent) + unrelated]
        case "events.subscribe":
            return ["subscriptionId": "events-\(params["replaceGroup"] as? String ?? "global")"]
        case "chat.subscribe":
            let agentId = params["agentId"] as? String ?? Self.parentId
            let subscriptionId = "chat-\(agentId)"
            connection.stubChatSnapshot(
                subscriptionId: subscriptionId,
                messages: [
                    [
                        "id": Self.messageId, "agentId": agentId, "role": "assistant",
                        "contentBlocks": [["type": "text", "id": "startup-text", "text": "Ready café 🦊"]]
                    ]
                ],
                meta: ["agentId": agentId, "truncated": false, "totalMessages": 1, "isResponding": false]
            )
            return ["subscriptionId": subscriptionId]
        default:
            return nil
        }
    }
}
