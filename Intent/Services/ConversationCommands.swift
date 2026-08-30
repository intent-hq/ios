import Foundation
import Observation

@MainActor
@Observable
final class ConversationCommands {
    struct AgentState {
        let isStreaming: Bool
        let attentionRequest: PendingAttentionRequest?
        let dismissedQuestionsMessageId: String?
        let lastSeenMessageId: String?
    }

    struct SubscriptionSnapshot {
        let watchedAgentIds: [String]
        let delegationGroupStatus: (completed: Int, total: Int)?
    }

    var queuedMessages: [QueuedMessage] = []
    var dismissedQuestionsMessageId: String?
    var lastSeenMessageId: String?

    @ObservationIgnored private let connectionManager: ConnectionManagerRouting
    private var lastMarkSeenSentId: String?

    init(connectionManager: ConnectionManagerRouting) {
        self.connectionManager = connectionManager
    }

    func fetchAgentState(agentId: String) async throws -> AgentState? {
        let result = try await connectionManager.request(
            "agent.get", params: ["agentId": agentId])
        guard let response = result as? [String: Any],
              let agent = response["agent"] as? [String: Any] else { return nil }
        let metadata = agent["metadata"] as? [String: Any]
        return AgentState(
            isStreaming: (agent["isStreaming"] as? Bool ?? false)
                || (agent["isResponding"] as? Bool ?? false)
                || (agent["turnInFlight"] as? Bool ?? false),
            attentionRequest: AgentSession.parsePendingAttentionRequest(agent),
            dismissedQuestionsMessageId: metadata?["dismissedQuestionsMessageId"] as? String,
            lastSeenMessageId: metadata?["lastSeenMessageId"] as? String
        )
    }

    func subscribeToEvents(agentId: String, workspaceId: String) async throws -> String? {
        let result = try await connectionManager.request(
            "events.subscribe",
            params: [
                "eventTypes": [
                    "agent:stream:*", "agent:queue:*", "agent:user-message:*",
                    "agent:subscribed", "agent:unsubscribed",
                    "agent:status-changed", "agent:idle",
                    "agent:woken-by-subscription", "agent:deleted", "agent:updated",
                ],
                "workspaceId": workspaceId,
                "replaceGroup": "streaming-\(agentId)",
            ]
        )
        return (result as? [String: Any])?["subscriptionId"] as? String
    }

    func unsubscribeEvents(subscriptionId: String) async throws {
        _ = try await connectionManager.request(
            "events.unsubscribe", params: ["subscriptionId": subscriptionId])
    }

    func sendMessage(
        agentId: String,
        content: String,
        workspaceId: String,
        messageId: String,
        imageBlocks: [[String: Any]]?,
        fileBlocks: [[String: Any]]?,
        messageMetadata: [String: Any]?
    ) async throws -> Bool {
        var params: [String: Any] = [
            "agentId": agentId,
            "content": content,
            "workspaceId": workspaceId,
            "messageId": messageId,
        ]
        if let imageBlocks { params["imageBlocks"] = imageBlocks }
        if let fileBlocks { params["fileBlocks"] = fileBlocks }
        if let messageMetadata { params["messageMetadata"] = messageMetadata }
        let result = try await connectionManager.request("agent.sendMessage", params: params)
        return (result as? [String: Any])?["queued"] as? Bool == true
    }

    func dismissQuestions(
        agentId: String, messageId: String, workspaceId: String
    ) async throws {
        let previousMarker = dismissedQuestionsMessageId
        dismissedQuestionsMessageId = messageId
        do {
            let result = try await connectionManager.request(
                "agent.dismissQuestions",
                params: [
                    "agentId": agentId,
                    "messageId": messageId,
                    "workspaceId": workspaceId,
                ]
            )
            if let confirmedId = (result as? [String: Any])?["dismissedQuestionsMessageId"]
                as? String {
                dismissedQuestionsMessageId = confirmedId
            }
        } catch {
            if dismissedQuestionsMessageId == messageId {
                dismissedQuestionsMessageId = previousMarker
            }
            throw error
        }
    }

    func markSeen(
        agentId: String, workspaceId: String, messages: [ConversationMessage]
    ) async {
        guard let messageId = messages.reversed().first(where: {
            $0.isStreaming != true && !$0.id.isEmpty
        })?.id else { return }
        if messageId == lastMarkSeenSentId || messageId == lastSeenMessageId { return }
        lastMarkSeenSentId = messageId
        do {
            let result = try await connectionManager.request(
                "agent.markSeen",
                params: [
                    "agentId": agentId,
                    "messageId": messageId,
                    "workspaceId": workspaceId,
                ]
            )
            if let confirmedId = (result as? [String: Any])?["lastSeenMessageId"] as? String {
                lastSeenMessageId = confirmedId
            }
        } catch {
            if lastMarkSeenSentId == messageId { lastMarkSeenSentId = nil }
            AppLog.conversation.error("[ConversationStore] agent.markSeen failed: \(error)")
        }
    }

    func queueMessage(
        agentId: String,
        content: String,
        imageBlocks: [[String: Any]]?,
        fileBlocks: [[String: Any]]?
    ) async throws {
        var params: [String: Any] = ["agentId": agentId, "content": content]
        if let imageBlocks { params["imageBlocks"] = imageBlocks }
        if let fileBlocks { params["fileBlocks"] = fileBlocks }
        let result = try await connectionManager.request("agent.queueMessage", params: params)
        guard let response = result as? [String: Any],
              let dictionary = response["queuedMessage"] as? [String: Any],
              let data = try? JSONSerialization.data(withJSONObject: dictionary),
              let message = try? JSONDecoder().decode(QueuedMessage.self, from: data)
        else { return }
        queuedMessages.append(message)
    }

    func stop(agentId: String) async throws {
        _ = try await connectionManager.request("agent.stop", params: ["agentId": agentId])
    }

    func fetchQueue(agentId: String) async throws {
        let result = try await connectionManager.request(
            "agent.getQueue", params: ["agentId": agentId])
        guard let response = result as? [String: Any],
              let items = response["queue"] as? [[String: Any]] else { return }
        let data = try JSONSerialization.data(withJSONObject: items)
        queuedMessages = (try? JSONDecoder().decode([QueuedMessage].self, from: data)) ?? []
    }

    func editQueuedMessage(agentId: String, messageId: String, content: String) async throws {
        _ = try await connectionManager.request(
            "agent.editQueuedMessage",
            params: ["agentId": agentId, "messageId": messageId, "content": content])
        if let index = queuedMessages.firstIndex(where: { $0.id == messageId }) {
            queuedMessages[index].content = content
        }
    }

    func sendQueuedMessageNow(
        agentId: String, messageId: String, workspaceId: String
    ) async throws {
        let result: Any
        do {
            result = try await connectionManager.request(
                "agent.sendQueuedMessageNow",
                params: [
                    "agentId": agentId,
                    "workspaceId": workspaceId,
                    "messageId": messageId,
                ])
        } catch let error as NSError where error.isEntityNotFound {
            do {
                try await fetchQueue(agentId: agentId)
            } catch {
                AppLog.conversation.error("[ConversationStore] Failed to fetch queue: \(error)")
            }
            throw error
        } catch let error as NSError where error.domain == "WebSocket" && error.code == -32602 {
            AppLog.conversation.error(
                "[ConversationStore] UNEXPECTED -32602 without data.code == \"not-found\" for "
                    + "queued message \(messageId) (data.code: \(error.intentErrorDataCode ?? "absent")): "
                    + error.localizedDescription)
            throw error
        }
        if (result as? [String: Any])?["queued"] as? Bool == true { return }
        queuedMessages.removeAll { $0.id == messageId }
    }

    func removeQueuedMessage(agentId: String, messageId: String) async throws {
        _ = try await connectionManager.request(
            "agent.removeQueuedMessage",
            params: ["agentId": agentId, "messageId": messageId])
        queuedMessages.removeAll { $0.id == messageId }
    }

    func getModels(agentId: String) async throws -> [[String: Any]] {
        let result = try await connectionManager.request(
            "agent.getModels", params: ["agentId": agentId])
        return (result as? [String: Any])?["models"] as? [[String: Any]] ?? []
    }

    func setModel(agentId: String, modelId: String, workspaceId: String) async throws {
        _ = try await connectionManager.request(
            "agent.setModel",
            params: ["agentId": agentId, "modelId": modelId, "workspaceId": workspaceId])
    }

    func fetchSubscriptions(
        agentId: String, workspaceId: String
    ) async throws -> SubscriptionSnapshot? {
        let result = try await connectionManager.request(
            "agent.getSubscriptions",
            params: ["agentId": agentId, "workspaceId": workspaceId])
        guard let response = result as? [String: Any] else { return nil }
        let subscriptions = response["subscriptions"] as? [[String: Any]] ?? []
        let groups = response["delegationGroups"] as? [[String: Any]] ?? []
        var agentIds = Set<String>()
        for group in groups {
            agentIds.formUnion(group["expectedAgentIds"] as? [String] ?? [])
        }
        for subscription in subscriptions {
            if let actorIds = subscription["actorIds"] as? [String] {
                agentIds.formUnion(actorIds)
            } else if let filter = subscription["filter"] as? [String: Any] {
                agentIds.formUnion(filter["actorIds"] as? [String] ?? [])
            }
        }
        let status: (completed: Int, total: Int)? = groups.isEmpty ? nil : groups.reduce(
            into: (completed: 0, total: 0)
        ) { status, group in
            status.completed += (group["completedAgentIds"] as? [String])?.count ?? 0
            status.total += (group["expectedAgentIds"] as? [String])?.count ?? 0
        }
        return SubscriptionSnapshot(
            watchedAgentIds: Array(agentIds), delegationGroupStatus: status)
    }

    func cancelSubscriptions(agentId: String, workspaceId: String) async throws {
        _ = try await connectionManager.request(
            "agent.cancelSubscriptions",
            params: ["agentId": agentId, "workspaceId": workspaceId])
    }

    func fetchAgent(agentId: String) async throws -> AgentSession? {
        let result = try await connectionManager.request(
            "agent.get", params: ["agentId": agentId])
        guard let response = result as? [String: Any],
              let dictionary = response["agent"] as? [String: Any] else { return nil }
        return AgentSession.parseAgent(dictionary)
    }

    func listAgents(workspaceId: String, watchedAgentIds: [String]) async throws -> [AgentSession]? {
        let result = try await connectionManager.request(
            "agent.list", params: ["workspaceId": workspaceId])
        guard let response = result as? [String: Any],
              let dictionaries = response["agents"] as? [[String: Any]] else { return nil }
        let watchedSet = Set(watchedAgentIds)
        return dictionaries.compactMap(AgentSession.parseAgent).filter { watchedSet.contains($0.id) }
    }

    func reset() {
        queuedMessages = []
        dismissedQuestionsMessageId = nil
        lastSeenMessageId = nil
        lastMarkSeenSentId = nil
    }
}