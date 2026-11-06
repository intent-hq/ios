import Foundation
@testable import Intent
import Testing

/// Uses the real backend session composition across actual view models. A second
/// panel shares conversation, detail and workspace status owners. The recorder
/// measures every request made by those owners, including window/row leases.
@MainActor
final class ConversationStartupFixture {
    static let workspaceId = "startup-workspace"
    static let parentId = "startup-parent"
    static let childId = "watched-child"
    static let messageId = "startup-message"
    let connection = RPCRecordingConnection()
    let session: BackendSession
    var options: CreationOptionsStore { session.creationOptionsStore }
    var details: AgentDetailStore { session.agentDetails }
    private var registrationNumber = 0
    private(set) var viewModels: [ConversationViewModel] = []
    var parentMetadata: [String: Any] = ["lastSeenMessageId": ConversationStartupFixture.messageId]
    var watchedIds: [String] = []
    var bundlesWatchedAgents = false
    var unrelatedAgentCount = 0
    var modelId: String?
    var providerId: String?

    init() {
        let connection = self.connection
        connection.holdsConnectionStateDelivery = true
        connection.simulateConnect()
        connection.globalSubscriptionState = .subscribed
        let workspaces = WorkspaceStore(forTesting: true)
        let fileLoader = WorkspaceFileImageLoader(connection: connection)
        session = BackendSession(
            backendID: nil,
            connection: connection,
            workspaceStore: workspaces,
            coordinatorFactory: { claim in
                AppCoordinator(workspaceStore: workspaces, connection: connection, claimScreenRestoration: claim)
            },
            githubRepoStore: GitHubRepoStore(connectionManager: connection),
            creationOptionsStore: CreationOptionsStore(connectionManager: connection),
            prMonitorsStore: WorkspacePrMonitorsStore(connectionManager: connection),
            attachmentUploadService: AttachmentUploadService(connection: connection),
            workspaceFileImageLoader: fileLoader,
            attachmentImageLoader: AttachmentImageLoader(connection: connection, fileLoader: fileLoader),
            attentionCueCenter: WorkspaceAttentionCueCenter {}
        )
        connection.responseMap = [
            "events.unsubscribe": [:], "chat.unsubscribe": [:], "browser.syncTabs": ["drop": [String]()],
            "agent.getQueue": ["queue": []],
            "hook.list": ["hooks": []], "prMonitor.list": ["monitors": []],
            "specialist.list": ["specialists": []], "models.list": ["models": []]
        ]
        connection.responseForRequest = { [weak self] method, params in
            self?.response(method: method, params: params)
        }
    }

    func makeViewModel(
        agentId: String = ConversationStartupFixture.parentId,
        workspaceId: String = ConversationStartupFixture.workspaceId
    ) -> ConversationViewModel {
        let viewModel = ConversationViewModel(
            agentId: agentId,
            workspaceId: workspaceId,
            agentName: "Startup fixture",
            connection: connection,
            uploadService: AttachmentUploadService(connection: connection),
            optionsStore: options,
            agentDetails: details,
            conversations: session.conversations,
            hooks: session.hooksStore,
            monitors: session.prMonitorsStore
        )
        viewModels.append(viewModel)
        return viewModel
    }

    func makeProposalStore(agentId: String = ConversationStartupFixture.parentId) -> ProposalActionStore {
        ProposalActionStore(connection: connection, agentId: agentId, workspaceId: Self.workspaceId, details: details)
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
        session.hooksStore.reset()
        session.prMonitorsStore.reset()
        for viewModel in viewModels {
            viewModel.teardownLiveStores()
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
        var response: [String: Any] = [
            "subscriptions": watchedIds.isEmpty ? [] : [["actorIds": watchedIds]],
            "delegationGroups": [],
            "agentStatuses": Dictionary(uniqueKeysWithValues: watchedIds.map { ($0, "active") })
        ]
        if bundlesWatchedAgents { response["agents"] = watchedIds.map(agent) }
        return response
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
            registrationNumber += 1
            return ["subscriptionId": "events-\(registrationNumber)"]
        case "chat.subscribe":
            let agentId = params["agentId"] as? String ?? Self.parentId
            registrationNumber += 1
            let subscriptionId = "chat-\(registrationNumber)"
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
