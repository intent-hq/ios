import Foundation
import Observation

@MainActor
@Observable
final class ConversationLiveTranscript {
    var messages: [ConversationMessage] = []
    var isStreaming = false {
        didSet {
            guard oldValue != isStreaming else { return }
            onStreamingChanged?(isStreaming)
        }
    }
    var isLoading = false
    var streamingUpdateCount = 0
    var isTruncated = false
    var totalMessageCount = 0
    var hydratingBlockKeys: Set<String> = []

    @ObservationIgnored var onStreamingChanged: (@MainActor (Bool) -> Void)?
    @ObservationIgnored var onInitialLoadCompleted: (@MainActor () -> Void)?
    @ObservationIgnored var onFetchError: (@MainActor (Error) -> Void)?

    private let connectionManager: ConnectionManagerRouting
    private var agentId: String?
    private var workspaceId: String?
    private var chatLive = false
    @ObservationIgnored private var chatSubscriptionId: String?
    private var chatChannelActive = false
    private var chatSeeded = false
    private var chatExpectedSeq = 0
    private var resnapshotInProgress = false
    private let blockDecoder = JSONDecoder()
    private let timestampFormatter = ISO8601DateFormatter()
    @ObservationIgnored private var hydratedBlocks: [String: ContentBlock] = [:]
    @ObservationIgnored private var hydratedBlockOrder: [String] = []

    private static let maxHydratedBlocks = 30

    init(connectionManager: ConnectionManagerRouting) {
        self.connectionManager = connectionManager
    }

    isolated deinit {
        if let subscriptionId = chatSubscriptionId {
            connectionManager.unregisterSubscriptionHandler(id: subscriptionId)
        }
    }

    func fetchConversation(agentId: String, workspaceId: String? = nil) async {
        self.agentId = agentId
        if let workspaceId {
            self.workspaceId = workspaceId
        }
        let isInitialLoad = messages.isEmpty
        if isInitialLoad {
            isLoading = true
        }

        do {
            var params: [String: Any] = [
                "agentId": agentId,
                "projection": "slim",
            ]
            if let workspaceId = workspaceId ?? self.workspaceId {
                params["workspaceId"] = workspaceId
            }
            let result = try await connectionManager.request(
                "agent.getConversation",
                params: params
            )
            if let response = result as? [String: Any],
               let items = response["messages"] as? [[String: Any]] {
                let fetched = items.compactMap { ConversationMessage.parseMessage($0) }
                isTruncated = response["truncated"] as? Bool ?? false
                totalMessageCount = response["totalMessages"] as? Int ?? fetched.count
                mergeFetchedMessages(fetched)
                remergeHydratedBlocks()

                if let last = messages.last,
                   last.role == .assistant,
                   last.isStreaming == true {
                    isStreaming = true
                }
            }
        } catch {
            onFetchError?(error)
            AppLog.conversation.error(
                "[ConversationStore] Failed to fetch conversation: \(error)")
        }

        if isInitialLoad {
            onInitialLoadCompleted?()
            isLoading = false
        }
    }

    private func mergeFetchedMessages(_ fetched: [ConversationMessage]) {
        guard !messages.isEmpty else {
            messages = fetched
            return
        }

        let fetchedIds = Set(fetched.map(\.id))
        messages.removeAll { existing in
            if fetchedIds.contains(existing.id) { return false }
            return !(existing.role == .assistant && existing.isStreaming == true)
        }

        for message in fetched {
            if let index = messages.firstIndex(where: { $0.id == message.id }) {
                messages[index] = message
            } else {
                messages.append(message)
            }
        }

        let order = Dictionary(uniqueKeysWithValues: fetched.enumerated().map { ($1.id, $0) })
        messages.sort {
            (order[$0.id] ?? Int.max) < (order[$1.id] ?? Int.max)
        }
    }

    static func hydratedBlockKey(messageId: String, blockId: String) -> String {
        "\(messageId)|\(blockId)"
    }

    func isBlockHydrated(messageId: String, blockId: String) -> Bool {
        hydratedBlocks[Self.hydratedBlockKey(messageId: messageId, blockId: blockId)] != nil
    }

    func hydratingBlockIds(forMessage messageId: String) -> Set<String> {
        let prefix = "\(messageId)|"
        return Set(hydratingBlockKeys.lazy
            .filter { $0.hasPrefix(prefix) }
            .map { String($0.dropFirst(prefix.count)) })
    }

    func hydrateBlock(messageId: String, blockId: String) async {
        guard let agentId else { return }
        let key = Self.hydratedBlockKey(messageId: messageId, blockId: blockId)
        if hydratedBlocks[key] != nil || hydratingBlockKeys.contains(key) { return }
        hydratingBlockKeys.insert(key)
        defer { hydratingBlockKeys.remove(key) }

        do {
            let result = try await connectionManager.request(
                "agent.getMessageBlock",
                params: [
                    "agentId": agentId,
                    "messageId": messageId,
                    "blockId": blockId,
                ]
            )
            guard self.agentId == agentId else { return }
            guard let response = result as? [String: Any],
                  let blockDictionary = response["block"] as? [String: Any],
                  let data = try? JSONSerialization.data(withJSONObject: blockDictionary),
                  let block = try? blockDecoder.decode(ContentBlock.self, from: data)
            else {
                AppLog.conversation.error(
                    "[ConversationStore] getMessageBlock returned no decodable block for \(key)")
                return
            }
            storeHydratedBlock(block, forKey: key)
            remergeHydratedBlocks()
        } catch {
            AppLog.conversation.error(
                "[ConversationStore] Failed to hydrate block \(key): \(error)")
        }
    }

    private func storeHydratedBlock(_ block: ContentBlock, forKey key: String) {
        if hydratedBlocks[key] == nil {
            hydratedBlockOrder.append(key)
        }
        hydratedBlocks[key] = block
        while hydratedBlockOrder.count > Self.maxHydratedBlocks {
            hydratedBlocks.removeValue(forKey: hydratedBlockOrder.removeFirst())
        }
    }

    private func remergeHydratedBlocks() {
        guard !hydratedBlocks.isEmpty else { return }
        for messageIndex in messages.indices {
            guard var blocks = messages[messageIndex].contentBlocks, !blocks.isEmpty else {
                continue
            }
            var changed = false
            for blockIndex in blocks.indices {
                let key = Self.hydratedBlockKey(
                    messageId: messages[messageIndex].id,
                    blockId: blocks[blockIndex].id
                )
                if let hydrated = hydratedBlocks[key] {
                    blocks[blockIndex] = hydrated
                    changed = true
                }
            }
            if changed {
                messages[messageIndex].contentBlocks = blocks
            }
        }
    }

    func subscribe(agentId: String, workspaceId: String? = nil) async {
        self.agentId = agentId
        if let workspaceId {
            self.workspaceId = workspaceId
        }
        chatChannelActive = true
        chatSeeded = false

        do {
            let result = try await connectionManager.request("chat.subscribe", params: [
                "agentId": agentId,
                "replaceGroup": "ios-chat-\(agentId)",
                "projection": "slim",
            ])
            guard let response = result as? [String: Any],
                  let subscriptionId = response["subscriptionId"] as? String
            else {
                clearChannelForLegacyFallback()
                return
            }

            if let previous = chatSubscriptionId, previous != subscriptionId {
                connectionManager.unregisterSubscriptionHandler(id: previous)
            }
            chatSubscriptionId = subscriptionId
            connectionManager.registerSubscriptionHandler(id: subscriptionId) { [weak self] push in
                self?.handlePush(push)
            }
            AppLog.conversation.info(
                "[ConversationStore] Subscribed to chat.subscribe: \(subscriptionId)")
        } catch {
            clearChannelForLegacyFallback()
            AppLog.conversation.warning(
                "[ConversationStore] chat.subscribe failed: \(error), falling back to legacy")
        }
    }

    private func clearChannelForLegacyFallback() {
        chatChannelActive = false
        chatLive = false
        chatSubscriptionId = nil
    }

    func setTestChannel(subscriptionId: String) {
        chatChannelActive = true
        chatSeeded = false
        chatSubscriptionId = subscriptionId
    }

    func handlePush(_ push: SubscriptionPush) {
        guard chatChannelActive else { return }
        if let subscriptionId = chatSubscriptionId,
           push.subscriptionId != subscriptionId {
            return
        }

        switch push.kind {
        case .snapshot:
            if chatSeeded && push.seq + 1 < chatExpectedSeq { return }
            applySnapshot(push)
        case .delta:
            guard let delta = push.delta else { return }
            if chatSeeded && push.seq == chatExpectedSeq {
                applyDelta(delta)
                chatExpectedSeq = push.seq + 1
            } else if chatSeeded && push.seq < chatExpectedSeq {
                return
            } else if !resnapshotInProgress {
                resnapshotInProgress = true
                AppLog.conversation.warning(
                    "[ConversationStore] Chat sequence gap detected at seq=\(push.seq), resubscribing...")
                Task { await resnapshot() }
            }
        }
    }

    private func applySnapshot(_ push: SubscriptionPush) {
        guard let items = push.snapshot else { return }
        chatLive = true
        chatSeeded = true
        chatExpectedSeq = push.seq + 1
        messages = items.compactMap { ConversationMessage.parseMessage($0) }
        remergeHydratedBlocks()

        isTruncated = push.snapshotMeta?["truncated"] as? Bool ?? false
        totalMessageCount = push.snapshotMeta?["totalMessages"] as? Int ?? messages.count
        let hasInFlightMessage = messages.contains { $0.isStreaming == true }
        let isResponding = push.snapshotMeta?["isResponding"] as? Bool ?? false
        let turnInFlight = push.snapshotMeta?["turnInFlight"] as? Bool ?? false
        isStreaming = hasInFlightMessage || isResponding || turnInFlight
        AppLog.conversation.debug(
            "[ConversationStore] Applied chat snapshot with \(items.count) messages, seq=\(push.seq), streaming=\(isStreaming)")
    }

    private func applyDelta(_ delta: SubscriptionPush.DeltaPayload) {
        var sawTerminal = false
        var sawUpsert = false
        for entity in delta.added + delta.updated {
            let result = upsertBlock(entity)
            sawUpsert = sawUpsert || result.applied
            sawTerminal = sawTerminal || result.terminal
        }

        if !delta.removedIds.isEmpty {
            let removedIds = Set(delta.removedIds)
            for index in messages.indices {
                guard var blocks = messages[index].contentBlocks else { continue }
                blocks.removeAll { removedIds.contains($0.id) }
                messages[index].contentBlocks = blocks
            }
        }
        remergeHydratedBlocks()

        if sawTerminal {
            isStreaming = false
            streamingUpdateCount = 0
        } else if sawUpsert {
            isStreaming = true
            streamingUpdateCount += 1
        }
        AppLog.conversation.debug(
            "[ConversationStore] Applied chat delta, added=\(delta.added.count), updated=\(delta.updated.count), removed=\(delta.removedIds.count), terminal=\(sawTerminal)")
    }

    private func upsertBlock(_ entity: [String: Any]) -> (applied: Bool, terminal: Bool) {
        guard let messageId = entity["messageId"] as? String,
              let blockDictionary = entity["block"] as? [String: Any],
              let data = try? JSONSerialization.data(withJSONObject: blockDictionary),
              let block = try? blockDecoder.decode(ContentBlock.self, from: data)
        else {
            return (false, false)
        }
        let streamingComplete = entity["streamingComplete"] as? Bool ?? false

        let messageIndex: Int
        if let existing = messages.firstIndex(where: { $0.id == messageId }) {
            messageIndex = existing
        } else {
            let role = MessageRole(rawValue: entity["role"] as? String ?? "assistant") ?? .system
            messages.append(ConversationMessage(
                id: messageId,
                role: role,
                contentBlocks: [],
                timestamp: entity["timestamp"] as? String
                    ?? timestampFormatter.string(from: Date()),
                isStreaming: !streamingComplete
            ))
            messageIndex = messages.count - 1
        }

        if let timestamp = entity["timestamp"] as? String, !timestamp.isEmpty {
            messages[messageIndex].timestamp = timestamp
        }
        var blocks = messages[messageIndex].contentBlocks ?? []
        if let index = blocks.firstIndex(where: { $0.id == block.id }) {
            blocks[index] = mergedToolUseBlock(prior: blocks[index], incoming: block)
        } else {
            blocks.append(block)
        }
        messages[messageIndex].contentBlocks = blocks
        messages[messageIndex].isStreaming = !streamingComplete

        let isAssistant = messages[messageIndex].role == .assistant
        return (isAssistant, isAssistant && streamingComplete)
    }

    private func mergedToolUseBlock(
        prior: ContentBlock,
        incoming: ContentBlock
    ) -> ContentBlock {
        guard incoming.type == .toolUse,
              prior.type == .toolUse,
              incoming.toolCallId != nil,
              incoming.toolCallId == prior.toolCallId,
              (incoming.resolvedName ?? "").isEmpty
        else {
            return incoming
        }
        var merged = incoming
        merged.name = prior.resolvedName
        merged.input = prior.input
        var metadata = merged.metadata ?? [:]
        if let toolKind = prior.metadata?["toolKind"] {
            metadata["toolKind"] = toolKind
        }
        merged.metadata = metadata
        return merged
    }

    private func resnapshot() async {
        resnapshotInProgress = true
        defer { resnapshotInProgress = false }
        chatLive = false
        chatSeeded = false

        if let subscriptionId = chatSubscriptionId {
            connectionManager.unregisterSubscriptionHandler(id: subscriptionId)
            do {
                _ = try await connectionManager.request("chat.unsubscribe", params: [
                    "subscriptionId": subscriptionId,
                ])
            } catch {
                AppLog.conversation.error(
                    "[ConversationStore] chat.unsubscribe failed: \(error)")
            }
        }
        chatSubscriptionId = nil

        if let agentId {
            await subscribe(agentId: agentId, workspaceId: workspaceId)
            await fetchConversation(agentId: agentId, workspaceId: workspaceId)
        }
    }

    func shouldSuppressFirehose(eventType: String) -> Bool {
        chatLive && eventType.hasPrefix("agent:stream:") && eventType != "agent:stream:end"
    }

    var shouldDiscardBufferedFirehose: Bool {
        chatLive
    }

    var shouldRefetchAfterLegacyStreamEnd: Bool {
        !chatLive
    }

    func prepareForReconnect() {
        chatLive = false
        if let subscriptionId = chatSubscriptionId {
            connectionManager.unregisterSubscriptionHandler(id: subscriptionId)
        }
        chatSubscriptionId = nil
        chatChannelActive = false
        chatSeeded = false
        resnapshotInProgress = false
    }

    func reset() {
        messages = []
        isStreaming = false
        isLoading = false
        streamingUpdateCount = 0
        isTruncated = false
        totalMessageCount = 0
        agentId = nil
        workspaceId = nil
        hydratingBlockKeys = []
        hydratedBlocks = [:]
        hydratedBlockOrder = []
        chatLive = false
        if let subscriptionId = chatSubscriptionId {
            connectionManager.unregisterSubscriptionHandler(id: subscriptionId)
        }
        chatSubscriptionId = nil
        chatChannelActive = false
        chatSeeded = false
        chatExpectedSeq = 0
        resnapshotInProgress = false
    }
}