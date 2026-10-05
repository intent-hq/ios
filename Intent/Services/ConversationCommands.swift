import Foundation

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
        let groups: [WatchedAgentGroup]
        let agentStatuses: [String: String]
        let agents: [[String: Any]]
        let summaryBoundary: AgentSummaryStore.ReadBoundary
    }

    var queuedMessages: [QueuedMessage] = [] {
        didSet { queueRevision &+= 1 }
    }
    var queueRevision = 0
    private var queueReadGeneration = 0
    private var queueSeedSequence = 0

    var queueReads: [UUID: QueueRead] = [:]
    @ObservationIgnored let queueMutations = QueueMutationHistory()
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
    private(set) var confirmedMarkerRevisions: [String: Int] = [:]
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

    /// Seeks one message; nil if absent, with unknown-id errors classified by the caller.
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

    func fetchOlderMessages(
        agentId: String, workspaceId: String?, nextToken: String
    ) async throws -> (messages: [ConversationMessage], nextToken: String?) {
        let pageSize = 50
        var params: [String: Any] = ["agentId": agentId, "limit": pageSize, "nextToken": nextToken, "projection": "slim"]
        if let workspaceId { params["workspaceId"] = workspaceId }
        let result = try await connectionManager.request("agent.getConversation", params: params)
        guard let response = result as? [String: Any],
              let items = response["messages"] as? [[String: Any]] else {
            throw URLError(.cannotParseResponse)
        }
        return (items.compactMap(ConversationMessage.parseMessage), response["nextToken"] as? String)
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
        try request.imagePayload.validateRequest(method: "agent.sendMessage", params: params)
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
                confirmedMarkerRevisions["dismissedQuestionsMessageId", default: 0] &+= 1
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
                confirmedMarkerRevisions["lastSeenMessageId", default: 0] &+= 1
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
        let generation = queueMutations.generation
        var params: [String: Any] = ["agentId": agentId, "content": content]
        imagePayload.apply(to: &params)
        filePayload.apply(to: &params)
        try imagePayload.validateRequest(method: "agent.queueMessage", params: params)
        let result = try await connectionManager.request("agent.queueMessage", params: params)
        guard let response = result as? [String: Any],
              let dictionary = response["queuedMessage"] as? [String: Any],
              let data = try? JSONSerialization.data(withJSONObject: dictionary),
              let message = try? JSONDecoder().decode(QueuedMessage.self, from: data)
        else { return }
        confirmQueueMutation(.append(message), generation: generation)
    }

    func stop(agentId: String) async throws {
        _ = try await connectionManager.request("agent.stop", params: ["agentId": agentId])
    }

    func invalidateQueueReads() { queueReadGeneration &+= 1 }

    func queueSeedSupersedes(_ receivedAt: Int) -> Bool { receivedAt < queueSeedSequence }

    /// Replaces the queue from agent.getQueue. Malformed envelopes preserve
    /// existing rows; a valid empty array clears them. Later acknowledged changes
    /// and processing removals fold in without discarding unrelated seed rows.
    func fetchQueue(agentId: String) async throws {
        let generation = resetGeneration
        let readGeneration = queueReadGeneration
        let read = QueueRead(revision: queueRevision, sequence: agentDetails.nextStateSequence())
        let readID = UUID()
        queueReads[readID] = read
        defer { queueReads[readID] = nil }
        let result = try await connectionManager.request(
            "agent.getQueue",
            params: ["agentId": agentId]
        )
        guard !Task.isCancelled, generation == resetGeneration,
              readGeneration == queueReadGeneration else { throw CancellationError() }
        guard read.revision == queueRevision else { return }
        guard let response = result as? [String: Any],
              let decoded = Self.decodeQueueSnapshot(response["queue"], source: "agent.getQueue")
        else {
            AppLog.conversation.error(
                "[ConversationStore] agent.getQueue returned a malformed envelope; keeping the "
                    + "previous queue (\(queuedMessages.count) entries)"
            )
            return
        }
        let isComplete = decoded.count == (response["queue"] as? [Any])?.count
        guard isComplete || !read.replayedEarlierEvent else { return }
        if isComplete { queueSeedSequence = read.sequence }
        queuedMessages = read.applying(to: decoded)
        onQueueSnapshot?(queuedMessages)
    }

    /// Shared getQueue/queue:updated decoder (PROTOCOL §5.5). Non-arrays return
    /// nil; invalid elements are dropped, retaining valid rows' order and ids.
    /// Logs only array positions/error shapes, never content or metadata.
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

    /// Content-free failure description: decoding case/path or other error type.
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
        let generation = queueMutations.generation
        _ = try await connectionManager.request(
            "agent.editQueuedMessage",
            params: ["agentId": agentId, "messageId": messageId, "content": content]
        )
        confirmQueueMutation(.edit(messageId, content: content, fallback: queuedMessages.first { $0.id == messageId }), generation: generation)
    }

    func sendQueuedMessageNow(
        agentId: String,
        messageId: String,
        workspaceId: String
    ) async throws {
        let generation = queueMutations.generation
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
            guard generation == queueMutations.generation else { throw error }
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
        confirmQueueMutation(.remove(messageId), generation: generation)
    }

    func removeQueuedMessage(agentId: String, messageId: String) async throws {
        let generation = queueMutations.generation
        _ = try await connectionManager.request(
            "agent.removeQueuedMessage",
            params: ["agentId": agentId, "messageId": messageId]
        )
        confirmQueueMutation(.remove(messageId), generation: generation)
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
        let summaryBoundary = agentDetails.summaries.beginRead()
        let result = try await connectionManager.request(
            "agent.getSubscriptions",
            params: ["agentId": agentId, "workspaceId": workspaceId]
        )
        guard let response = result as? [String: Any] else { return nil }
        let subscriptions = response["subscriptions"] as? [[String: Any]] ?? []
        let groups = (response["delegationGroups"] as? [[String: Any]] ?? []).map(WatchedAgentGroup.init)
        var agentIds = Set<String>()
        for group in groups {
            agentIds.formUnion(group.expectedAgentIds)
            agentIds.formUnion(group.completedAgentIds)
            agentIds.formUnion(group.deletedAgentIds)
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
            status.completed += group.completedAgentIds.union(group.deletedAgentIds).count
            status.total += group.expectedAgentIds.count
        }
        return SubscriptionSnapshot(
            watchedAgentIds: agentIds.sorted(),
            delegationGroupStatus: status,
            groups: groups,
            agentStatuses: (response["agentStatuses"] as? [String: Any] ?? [:])
                .compactMapValues { $0 as? String }.filter { agentIds.contains($0.key) },
            agents: (response["agents"] as? [[String: Any]] ?? []).filter { row in
                guard let id = row["id"] as? String, !id.isEmpty else { return false }
                return agentIds.contains(id)
            },
            summaryBoundary: summaryBoundary
        )
    }

    func cancelSubscriptions(agentId: String, workspaceId: String) async throws {
        _ = try await connectionManager.request(
            "agent.cancelSubscriptions",
            params: ["agentId": agentId, "workspaceId": workspaceId]
        )
    }

    func reset() {
        resetGeneration &+= 1
        queueMutations.cancel()
        queueSeedSequence = 0
        queuedMessages = []
        pendingQuestionsMessageId = nil
        dismissedQuestionsMessageId = nil
        lastSeenMessageId = nil
        lastMarkSeenSentId = nil
    }
}
