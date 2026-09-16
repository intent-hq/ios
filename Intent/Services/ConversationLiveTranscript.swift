import Foundation
import Observation

nonisolated struct InboundJSONValue: @unchecked Sendable {
    let value: Any
}

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
    /// Fired after the live chat channel replaced (snapshot) or merged (delta)
    /// the transcript, so the owner can reconcile state keyed on row residency.
    @ObservationIgnored var onTranscriptReplaced: (@MainActor () -> Void)?

    private let connectionManager: ConnectionManagerRouting
    private var agentId: String?
    private var workspaceId: String?
    /// Advances whenever the bound agent changes (or on `reset()`), never on a
    /// same-agent rebind. `whileBound` compares against it so work started
    /// under an earlier binding cannot publish into a later one.
    @ObservationIgnored private var bindingGeneration = 0
    /// Initial fetches (`isLoading = true`) still awaiting their page. A stale
    /// initial fetch only finishes the load when none is left in flight.
    @ObservationIgnored private var inFlightInitialLoads = 0
    private var chatLive = false
    @ObservationIgnored private var chatSubscriptionId: String?
    private var chatChannelActive = false
    private var chatSeeded = false
    private var chatExpectedSeq = 0
    private var resnapshotInProgress = false
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

    // MARK: - Binding

    private func bind(agentId newAgentId: String, workspaceId: String?) {
        if agentId != newAgentId {
            bindingGeneration &+= 1
        }
        agentId = newAgentId
        if let workspaceId {
            self.workspaceId = workspaceId
        }
    }

    /// Runs `work` and returns its value only if the transcript is still bound
    /// to the same agent it was when `work` started; otherwise the value is
    /// stale and `nil` is returned (after `onStale` had a chance to clean up
    /// side-effects the value carries, e.g. a server-side subscription).
    /// Errors thrown by `work` propagate regardless of staleness.
    func whileBound<T: Sendable>(
        _ work: () async throws -> T,
        onStale: (T) async -> Void = { _ in }
    ) async rethrows -> T? {
        let generation = bindingGeneration
        let value = try await work()
        guard generation == bindingGeneration else {
            await onStale(value)
            return nil
        }
        return value
    }

    func fetchConversation(agentId: String, workspaceId: String? = nil) async {
        bind(agentId: agentId, workspaceId: workspaceId)
        let isInitialLoad = messages.isEmpty
        if isInitialLoad {
            isLoading = true
            inFlightInitialLoads += 1
        }

        var params: [String: Any] = [
            "agentId": agentId,
            "projection": "slim",
        ]
        if let workspaceId = workspaceId ?? self.workspaceId {
            params["workspaceId"] = workspaceId
        }
        // Both awaits (RPC and off-main decode) yield MainActor; a rebind to
        // another agent in either window makes this page stale, so it must
        // not touch the new agent's transcript or streaming state. The error
        // is carried as a value so a stale failure is dropped with a stale
        // page: a not-found for the previous agent says nothing about the
        // current one and must not reach `onFetchError`.
        let outcome: Result<ConversationPage?, Error>? = await whileBound {
            do {
                let result = try await connectionManager.request(
                    "agent.getConversation",
                    params: params
                )
                return .success(await Self.decodeConversationPage(InboundJSONValue(value: result)))
            } catch {
                return .failure(error)
            }
        } onStale: { outcome in
            if case .failure(let error) = outcome {
                AppLog.conversation.debug(
                    "[ConversationStore] Dropped stale fetch failure for a previous binding: \(error)")
            }
        }

        switch outcome {
        case .success(let page?):
            isTruncated = page.truncated
            totalMessageCount = page.totalMessages ?? page.messages.count
            mergeFetchedMessages(page.messages)
            remergeHydratedBlocks()

            if let last = messages.last,
               last.role == .assistant,
               last.isStreaming == true {
                isStreaming = true
            }
        case .success(nil):
            break
        case .failure(let error):
            reportFetchError(error)
        case nil:
            break
        }

        if isInitialLoad {
            inFlightInitialLoads -= 1
            // A stale initial fetch must not finish the new binding's own
            // in-flight initial load; with none pending it still releases
            // `isLoading` so buffered events are not held forever.
            if outcome != nil || inFlightInitialLoads == 0 {
                onInitialLoadCompleted?()
                isLoading = false
            }
        }
    }

    private func reportFetchError(_ error: Error) {
        onFetchError?(error)
        AppLog.conversation.error(
            "[ConversationStore] Failed to fetch conversation: \(error)")
    }

    /// Decoded `agent.getConversation` response.
    private nonisolated struct ConversationPage: Sendable {
        let messages: [ConversationMessage]
        let truncated: Bool
        let totalMessages: Int?
    }

    // MARK: - Off-main decoding (`@concurrent`: the dict→Data→JSONDecoder
    // round-trip per message/block stays off MainActor; only the merge hops)

    @concurrent
    private nonisolated static func decodeConversationPage(_ result: InboundJSONValue) async -> ConversationPage? {
        guard let response = result.value as? [String: Any],
              let items = response["messages"] as? [[String: Any]] else { return nil }
        return ConversationPage(
            messages: items.compactMap { ConversationMessage.parseMessage($0) },
            truncated: response["truncated"] as? Bool ?? false,
            totalMessages: response["totalMessages"] as? Int
        )
    }

    @concurrent
    private nonisolated static func decodeMessageBlock(_ result: InboundJSONValue) async -> ContentBlock? {
        guard let response = result.value as? [String: Any],
              let blockDictionary = response["block"] as? [String: Any] else { return nil }
        return ContentBlock.decode(blockDictionary)
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
            let decoded = try await whileBound {
                let result = try await connectionManager.request(
                    "agent.getMessageBlock",
                    params: [
                        "agentId": agentId,
                        "messageId": messageId,
                        "blockId": blockId,
                    ]
                )
                return await Self.decodeMessageBlock(InboundJSONValue(value: result))
            }
            guard let decoded else { return }
            guard let block = decoded else {
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
            var blocks = messages[messageIndex].contentBlocks
            guard !blocks.isEmpty else { continue }
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
        bind(agentId: agentId, workspaceId: workspaceId)
        chatChannelActive = true
        chatSeeded = false

        // A reply (or failure) that lands after a rebind to another agent must
        // leave the new binding's channel state untouched, so the error is
        // carried as a value and only inspected on the still-bound path.
        let outcome: Result<String?, Error>? = await whileBound {
            do {
                let result = try await connectionManager.request("chat.subscribe", params: [
                    "agentId": agentId,
                    "replaceGroup": "ios-chat-\(agentId)",
                    "projection": "slim",
                ])
                return .success((result as? [String: Any])?["subscriptionId"] as? String)
            } catch {
                return .failure(error)
            }
        } onStale: { outcome in
            if case .success(let orphanedId?) = outcome {
                await releaseOrphanedSubscription(orphanedId)
            }
        }
        guard let outcome else { return }

        switch outcome {
        case .success(let subscriptionId?):
            if let previous = chatSubscriptionId, previous != subscriptionId {
                connectionManager.unregisterSubscriptionHandler(id: previous)
            }
            chatSubscriptionId = subscriptionId
            connectionManager.registerSubscriptionHandler(id: subscriptionId) { [weak self] push in
                self?.handlePush(push)
            }
            AppLog.conversation.info(
                "[ConversationStore] Subscribed to chat.subscribe: \(subscriptionId)")
        case .success(nil):
            clearChannelForLegacyFallback()
        case .failure(let error):
            clearChannelForLegacyFallback()
            AppLog.conversation.warning(
                "[ConversationStore] chat.subscribe failed: \(error), falling back to legacy")
        }
    }

    /// Best-effort release of a subscription the daemon opened for a binding
    /// we have since left, so it does not keep pushing for the old agent.
    private func releaseOrphanedSubscription(_ subscriptionId: String) async {
        guard subscriptionId != chatSubscriptionId else { return }
        do {
            _ = try await connectionManager.request("chat.unsubscribe", params: [
                "subscriptionId": subscriptionId,
            ])
        } catch {
            AppLog.conversation.error(
                "[ConversationStore] chat.unsubscribe of orphaned \(subscriptionId) failed: \(error)")
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
        // `parse` pre-decodes off MainActor; the fallback covers pushes built
        // directly from raw dictionaries (tests).
        messages = push.snapshotMessages ?? items.compactMap { ConversationMessage.parseMessage($0) }
        remergeHydratedBlocks()

        isTruncated = push.snapshotMeta?["truncated"] as? Bool ?? false
        totalMessageCount = push.snapshotMeta?["totalMessages"] as? Int ?? messages.count
        let hasInFlightMessage = messages.contains { $0.isStreaming == true }
        let isResponding = push.snapshotMeta?["isResponding"] as? Bool ?? false
        let turnInFlight = push.snapshotMeta?["turnInFlight"] as? Bool ?? false
        isStreaming = hasInFlightMessage || isResponding || turnInFlight
        AppLog.conversation.debug(
            "[ConversationStore] Applied chat snapshot with \(items.count) messages, seq=\(push.seq), streaming=\(isStreaming)")
        onTranscriptReplaced?()
    }

    private func applyDelta(_ delta: SubscriptionPush.DeltaPayload) {
        var sawTerminal = false
        var sawUpsert = false
        let entities = delta.chatBlocks
            ?? (delta.added + delta.updated).compactMap { SubscriptionPush.ChatBlockEntity(entity: $0) }
        for entity in entities {
            let result = upsertBlock(entity)
            sawUpsert = sawUpsert || result.applied
            sawTerminal = sawTerminal || result.terminal
        }

        if !delta.removedIds.isEmpty {
            let removedIds = Set(delta.removedIds)
            for index in messages.indices {
                var blocks = messages[index].contentBlocks
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
        onTranscriptReplaced?()
    }

    private func upsertBlock(_ entity: SubscriptionPush.ChatBlockEntity) -> (applied: Bool, terminal: Bool) {
        let messageId = entity.messageId
        let block = entity.block
        let streamingComplete = entity.streamingComplete

        let messageIndex: Int
        if let existing = messages.firstIndex(where: { $0.id == messageId }) {
            messageIndex = existing
        } else {
            messages.append(ConversationMessage(
                id: messageId,
                role: entity.role,
                contentBlocks: [],
                timestamp: entity.timestamp ?? timestampFormatter.string(from: Date()),
                streamingState: !streamingComplete ? .streaming : .complete
            ))
            messageIndex = messages.count - 1
        }

        if let timestamp = entity.timestamp, !timestamp.isEmpty {
            messages[messageIndex].timestamp = timestamp
        }
        var blocks = messages[messageIndex].contentBlocks
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
        var metadata = merged.metadata
        if let toolKind = prior.metadata["toolKind"] {
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
        bindingGeneration &+= 1
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