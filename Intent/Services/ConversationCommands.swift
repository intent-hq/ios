import Foundation

enum OutgoingImagePayload {
    case attachments([[String: Any]])
    case none

    func apply(to params: inout [String: Any]) {
        if case let .attachments(blocks) = self { params["imageBlocks"] = blocks }
    }
}

enum OutgoingFilePayload {
    case attachments([[String: Any]])
    case none

    func apply(to params: inout [String: Any]) {
        if case let .attachments(blocks) = self { params["fileBlocks"] = blocks }
    }
}

enum MessageSendMetadata {
    case fields([String: Any])
    case none

    func apply(to params: inout [String: Any]) {
        if case let .fields(fields) = self { params["messageMetadata"] = fields }
    }

    var optimisticFields: [String: AnyCodable] {
        guard case let .fields(fields) = self else { return [:] }
        return fields.mapValues(AnyCodable.init)
    }

    var wasProvided: Bool {
        if case .fields = self { return true }
        return false
    }
}

enum AgentListFetchResult {
    case sessions([AgentSession])
    case unavailable
}
import Observation

@MainActor
@Observable
final class ConversationCommands {
    // JSON-RPC Invalid params, also used by the daemon for unknown entity ids.
    private static let invalidParametersErrorCode = -32_602

    struct AgentState {
        let isStreaming: Bool
        /// PROTOCOL §5.5 three-state marker: `nil` when absent from the
        /// response (legacy daemon), `""` when written-empty (nothing
        /// pending), else the question-bearing message id. Never coerced.
        let pendingQuestionsMessageId: String?
        let dismissedQuestionsMessageId: String?
        let lastSeenMessageId: String?
    }

    struct SubscriptionSnapshot {
        let watchedAgentIds: [String]
        let delegationGroupStatus: (completed: Int, total: Int)?
    }

    var queuedMessages: [QueuedMessage] = [] {
        didSet { queueRevision &+= 1 }
    }
    private var queueRevision = 0
    private var queueReadGeneration = 0
    @ObservationIgnored var onQueueSnapshot: (([QueuedMessage]) -> Void)?
    var pendingQuestionsMessageId: String? {
        didSet {
            markerRevision &+= 1
            pendingMarkerRevision &+= 1
        }
    }
    var dismissedQuestionsMessageId: String? {
        didSet {
            markerRevision &+= 1
            dismissedMarkerRevision &+= 1
        }
    }
    private(set) var pendingMarkerRevision = 0
    private(set) var dismissedMarkerRevision = 0
    var lastSeenMessageId: String? {
        didSet {
            markerRevision &+= 1
            seenMarkerRevision &+= 1
        }
    }
    private(set) var seenMarkerRevision = 0
    private(set) var markerRevision = 0
    let agentDetails: AgentDetailStore

    @ObservationIgnored private let connectionManager: ConnectionManagerRouting
    private var lastMarkSeenSentId: String?
    private var resetGeneration = 0

    init(connectionManager: ConnectionManagerRouting, agentDetails: AgentDetailStore? = nil) {
        self.connectionManager = connectionManager
        self.agentDetails = agentDetails ?? AgentDetailStore(connection: connectionManager)
    }
}

extension ConversationCommands {
    func fetchAgentState(agentId: String, workspaceId: String? = nil, refresh: Bool = true) async throws -> AgentState? {
        let detail = try await agentDetails.load(agentId: agentId, workspaceId: workspaceId, refresh: refresh)
        let agent = detail.values
        let metadata = detail.metadata
        return AgentState(
            isStreaming: (agent["isStreaming"] as? Bool ?? false)
                || (agent["isResponding"] as? Bool ?? false)
                || (agent["turnInFlight"] as? Bool ?? false),
            pendingQuestionsMessageId: metadata["pendingQuestionsMessageId"] as? String,
            dismissedQuestionsMessageId: metadata["dismissedQuestionsMessageId"] as? String,
            lastSeenMessageId: metadata["lastSeenMessageId"] as? String
        )
    }

    /// Targeted seek for one message outside the loaded page
    /// (`agent.getConversation` with `aroundMessageId` + `limit: 1`, PROTOCOL
    /// §5.5). Returns the row when the page contains it, nil when the daemon
    /// served a page without it. An unknown id surfaces as the daemon's
    /// `-32602` (`unknown message id`) — the caller classifies it.
    func fetchMessage(
        agentId: String,
        messageId: String,
        workspaceId: String?
    ) async throws -> ConversationMessage? {
        var params: [String: Any] = [
            "agentId": agentId,
            "aroundMessageId": messageId,
            "limit": 1,
            "projection": "slim"
        ]
        if let workspaceId { params["workspaceId"] = workspaceId }
        let result = try await connectionManager.request("agent.getConversation", params: params)
        guard let response = result as? [String: Any],
              let items = response["messages"] as? [[String: Any]] else { return nil }
        return items.compactMap(ConversationMessage.parseMessage).first { $0.id == messageId }
    }

    func sendMessage(_ request: SendRequest) async throws -> SendAcceptance {
        let generation = resetGeneration
        let issuedQueueRevision = queueRevision
        var params: [String: Any] = [
            "agentId": request.agentId,
            "content": request.content,
            "workspaceId": request.workspaceId,
            "messageId": request.messageId,
            // Correlates auto-queue + drain; NOT a replay/dedup guarantee (PROTOCOL §5.5).
            "userAppMessageId": request.messageId
        ]
        request.imagePayload.apply(to: &params)
        request.filePayload.apply(to: &params)
        request.messageMetadata.apply(to: &params)
        let result = try await connectionManager.request("agent.sendMessage", params: params)
        guard generation == resetGeneration else { throw CancellationError() }
        guard let response = result as? [String: Any],
              response["success"] as? Bool == true,
              let queued = response["queued"] as? Bool else {
            throw ConversationSendError.invalidAcknowledgement
        }
        if !queued { return SendAcceptance(queued: false, messageId: response["messageId"] as? String) }
        // Seed only if no newer queue event/read landed during the request.
        // The store also skips seeding when a transcript echo already won.
        var seed: QueuedMessage?
        if let dictionary = response["queuedMessage"] as? [String: Any],
           let data = try? JSONSerialization.data(withJSONObject: dictionary),
           let message = try? JSONDecoder().decode(QueuedMessage.self, from: data),
           issuedQueueRevision == queueRevision {
            seed = message
        }
        let queuedId = (response["queuedMessage"] as? [String: Any])?["id"] as? String
        return SendAcceptance(queued: true, messageId: queuedId, queueSeed: seed)
    }

    func dismissQuestions(
        agentId: String,
        messageId: String,
        workspaceId: String
    ) async throws {
        let previousMarker = dismissedQuestionsMessageId
        dismissedQuestionsMessageId = messageId
        do {
            let result = try await connectionManager.request(
                "agent.dismissQuestions",
                params: [
                    "agentId": agentId,
                    "messageId": messageId,
                    "workspaceId": workspaceId
                ]
            )
            if let confirmedId = (result as? [String: Any])?["dismissedQuestionsMessageId"]
                as? String {
                dismissedQuestionsMessageId = confirmedId
                agentDetails.updateMetadata(agentId: agentId, fields: ["dismissedQuestionsMessageId": confirmedId])
            }
        } catch {
            if dismissedQuestionsMessageId == messageId {
                dismissedQuestionsMessageId = previousMarker
            }
            throw error
        }
    }

    func markSeen(
        agentId: String,
        workspaceId: String,
        messages: [ConversationMessage]
    ) async {
        guard let messageId = messages.reversed().first(where: { message in
            message.isStreaming != true && !message.id.isEmpty
        })?.id else { return }
        if messageId == lastMarkSeenSentId || messageId == lastSeenMessageId { return }
        lastMarkSeenSentId = messageId
        do {
            let result = try await connectionManager.request(
                "agent.markSeen",
                params: [
                    "agentId": agentId,
                    "messageId": messageId,
                    "workspaceId": workspaceId
                ]
            )
            if let confirmedId = (result as? [String: Any])?["lastSeenMessageId"] as? String {
                lastSeenMessageId = confirmedId
                agentDetails.updateMetadata(agentId: agentId, fields: ["lastSeenMessageId": confirmedId])
            }
        } catch {
            if lastMarkSeenSentId == messageId { lastMarkSeenSentId = nil }
            AppLog.conversation.error("[ConversationStore] agent.markSeen failed: \(error)")
        }
    }

    func queueMessage(
        agentId: String,
        content: String,
        imagePayload: OutgoingImagePayload,
        filePayload: OutgoingFilePayload
    ) async throws {
        var params: [String: Any] = ["agentId": agentId, "content": content]
        imagePayload.apply(to: &params)
        filePayload.apply(to: &params)
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

    /// Replaces the local queue with the daemon's `agent.getQueue` snapshot.
    ///
    /// Malformed-envelope policy: when the response is not an object carrying
    /// a `queue` array, the previous local queue is kept unchanged — the
    /// daemon told us nothing usable, so blanking would lose entries the user
    /// can still see and act on. A well-formed empty `queue` is authoritative
    /// and clears the queue. Elements are decoded one by one (see
    /// `decodeQueueSnapshot`) so one malformed entry never blanks its siblings.
    func invalidateQueueReads() { queueReadGeneration &+= 1 }

    func fetchQueue(agentId: String) async throws {
        let generation = resetGeneration
        let readGeneration = queueReadGeneration
        let revision = queueRevision
        let result = try await connectionManager.request(
            "agent.getQueue",
            params: ["agentId": agentId]
        )
        guard !Task.isCancelled, generation == resetGeneration,
              readGeneration == queueReadGeneration else { throw CancellationError() }
        guard revision == queueRevision else { return }
        guard let response = result as? [String: Any],
              let decoded = Self.decodeQueueSnapshot(response["queue"], source: "agent.getQueue")
        else {
            AppLog.conversation.error(
                "[ConversationStore] agent.getQueue returned a malformed envelope; keeping the "
                    + "previous queue (\(queuedMessages.count) entries)"
            )
            return
        }
        queuedMessages = decoded
        onQueueSnapshot?(decoded)
    }

    /// Element-tolerant decoding shared by the `agent.getQueue` response and
    /// the `agent:queue:updated` push (PROTOCOL §5.5). Returns `nil` when
    /// `queue` is not an array (malformed envelope — callers decide the
    /// policy); otherwise every element that fails to decode is dropped and
    /// the valid siblings are returned in their original order with their
    /// identities intact. Only safe metadata (position in the array, error
    /// shape) is logged — never message content or metadata payloads.
    static func decodeQueueSnapshot(
        _ queue: Any?, source: String
    ) -> [QueuedMessage]? { // swiftlint:disable:this discouraged_optional_collection
        guard let items = queue as? [Any] else { return nil }
        let decoder = JSONDecoder()
        var messages: [QueuedMessage] = []
        messages.reserveCapacity(items.count)
        for (index, item) in items.enumerated() {
            do {
                guard let dictionary = item as? [String: Any] else {
                    throw DecodingError.typeMismatch(
                        [String: Any].self,
                        DecodingError.Context(
                            codingPath: [],
                            debugDescription: "element is not an object"
                        )
                    )
                }
                let data = try JSONSerialization.data(withJSONObject: dictionary)
                messages.append(try decoder.decode(QueuedMessage.self, from: data))
            } catch {
                AppLog.conversation.error(
                    "[ConversationStore] Dropping undecodable queue element \(index + 1)/"
                        + "\(items.count) from \(source): \(Self.describeDecodingFailure(error))"
                )
            }
        }
        return messages
    }

    /// Content-free description of a queue element decoding failure: the
    /// `DecodingError` case and the coding path that failed, or the error
    /// type for anything else.
    private static func describeDecodingFailure(_ error: Error) -> String {
        guard let decodingError = error as? DecodingError else {
            return String(describing: type(of: error))
        }
        let path: (DecodingError.Context) -> String = { context in
            context.codingPath.map(\.stringValue).joined(separator: ".")
        }
        if case let .keyNotFound(key, context) = decodingError {
            return "keyNotFound(\(key.stringValue)) at [\(path(context))]"
        }
        if case let .typeMismatch(_, context) = decodingError {
            return "typeMismatch at [\(path(context))]"
        }
        if case let .valueNotFound(_, context) = decodingError {
            return "valueNotFound at [\(path(context))]"
        }
        if case .dataCorrupted(let context) = decodingError {
            return "dataCorrupted at [\(path(context))]"
        }
        return "DecodingError"
    }

    func editQueuedMessage(agentId: String, messageId: String, content: String) async throws {
        _ = try await connectionManager.request(
            "agent.editQueuedMessage",
            params: ["agentId": agentId, "messageId": messageId, "content": content]
        )
        if let index = queuedMessages.firstIndex(where: { $0.id == messageId }) {
            queuedMessages[index].content = content
        }
    }

    func sendQueuedMessageNow(
        agentId: String,
        messageId: String,
        workspaceId: String
    ) async throws {
        let result: Any
        do {
            result = try await connectionManager.request(
                "agent.sendQueuedMessageNow",
                params: [
                    "agentId": agentId,
                    "workspaceId": workspaceId,
                    "messageId": messageId
                ]
            )
        } catch let error as NSError where error.isEntityNotFound {
            do {
                try await fetchQueue(agentId: agentId)
            } catch {
                AppLog.conversation.error("[ConversationStore] Failed to fetch queue: \(error)")
            }
            throw error
        } catch let error as NSError
            where error.domain == "WebSocket" && error.code == Self.invalidParametersErrorCode {
            AppLog.conversation.error(
                "[ConversationStore] UNEXPECTED -32602 without data.code == \"not-found\" for "
                    + "queued message \(messageId) (data.code: \(error.intentErrorDataCode ?? "absent")): "
                    + error.localizedDescription
            )
            throw error
        }
        if (result as? [String: Any])?["queued"] as? Bool == true { return }
        queuedMessages.removeAll { $0.id == messageId }
    }

    func removeQueuedMessage(agentId: String, messageId: String) async throws {
        _ = try await connectionManager.request(
            "agent.removeQueuedMessage",
            params: ["agentId": agentId, "messageId": messageId]
        )
        queuedMessages.removeAll { $0.id == messageId }
    }

    func getModels(agentId: String) async throws -> [[String: Any]] {
        let result = try await connectionManager.request(
            "agent.getModels",
            params: ["agentId": agentId]
        )
        return (result as? [String: Any])?["models"] as? [[String: Any]] ?? []
    }

    func setModel(agentId: String, modelId: String, workspaceId: String) async throws {
        _ = try await connectionManager.request(
            "agent.setModel",
            params: ["agentId": agentId, "modelId": modelId, "workspaceId": workspaceId]
        )
    }

    func fetchSubscriptions(
        agentId: String,
        workspaceId: String
    ) async throws -> SubscriptionSnapshot? {
        let result = try await connectionManager.request(
            "agent.getSubscriptions",
            params: ["agentId": agentId, "workspaceId": workspaceId]
        )
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
            watchedAgentIds: Array(agentIds),
            delegationGroupStatus: status
        )
    }

    func cancelSubscriptions(agentId: String, workspaceId: String) async throws {
        _ = try await connectionManager.request(
            "agent.cancelSubscriptions",
            params: ["agentId": agentId, "workspaceId": workspaceId]
        )
    }

    func fetchAgent(agentId: String) async throws -> AgentSession? {
        let detail = try await agentDetails.load(agentId: agentId, refresh: true)
        return AgentSession.parseAgent(detail.values)
    }

    func listAgents(workspaceId: String, watchedAgentIds: [String]) async throws -> AgentListFetchResult {
        let result = try await connectionManager.request(
            "agent.list",
            params: ["workspaceId": workspaceId]
        )
        guard let response = result as? [String: Any],
              let dictionaries = response["agents"] as? [[String: Any]] else { return .unavailable }
        let watchedSet = Set(watchedAgentIds)
        return .sessions(
            dictionaries.compactMap(AgentSession.parseAgent).filter { watchedSet.contains($0.id) }
        )
    }

    func reset() {
        resetGeneration &+= 1
        queuedMessages = []
        pendingQuestionsMessageId = nil
        dismissedQuestionsMessageId = nil
        lastSeenMessageId = nil
        lastMarkSeenSentId = nil
    }
}
