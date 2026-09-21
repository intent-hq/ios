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
    /// Fired when `chat.subscribe` is rejected for the still-bound agent.
    @ObservationIgnored var onSubscribeError: (@MainActor (Error) -> Void)?
    /// Fired after the live chat channel replaced (snapshot) or merged (delta)
    /// the transcript, so the owner can reconcile state keyed on row residency.
    @ObservationIgnored var onTranscriptReplaced: (@MainActor () -> Void)?

    let connectionManager: ConnectionManagerRouting
    var agentId: String?
    var workspaceId: String?
    /// Advances whenever the bound agent changes (or on `reset()`), never on a
    /// same-agent rebind. `whileBound` compares against it so work started
    /// under an earlier binding cannot publish into a later one.
    @ObservationIgnored var bindingGeneration = 0
    /// Advances on every `chat.subscribe` registration and channel teardown
    /// (`reset`, reconnect), same-agent ones included. A reply, push, timeout
    /// or retry that outlived its registration is validated against it after
    /// each suspension and dropped, so it cannot replace or clear the newer
    /// channel.
    @ObservationIgnored var registrationGeneration = 0
    /// Advances each time the live chat channel applies a snapshot or delta.
    /// A streaming-state response captured before it moved is stale.
    @ObservationIgnored var liveStateVersion = 0
    /// Ceiling on the seq-0 snapshot after a `chat.subscribe` ack; past it the
    /// registration is presumed stale and replaced on the retry schedule.
    @ObservationIgnored var snapshotTimeout = ConversationLiveTranscript.defaultSnapshotTimeout
    /// Self-heal backoff for a rejected registration or a missing seq-0
    /// snapshot: one delayed re-registration, doubling per consecutive
    /// failure up to `maxRetryDelay`, reset when a snapshot applies or the
    /// transport reconnects (mirrors cloudlands-fe's `LiveChatClient`).
    @ObservationIgnored var initialRetryDelay = ConversationLiveTranscript.defaultInitialRetryDelay
    @ObservationIgnored var maxRetryDelay = ConversationLiveTranscript.defaultMaxRetryDelay
    /// Delay of the next scheduled retry; `nil` until the first failure after
    /// a reset, so it starts from `initialRetryDelay`.
    @ObservationIgnored var nextRetryDelay: Duration?
    @ObservationIgnored var snapshotTimeoutTask: Task<Void, Never>?
    @ObservationIgnored var retryTask: Task<Void, Never>?
    /// `awaitSnapshot` calls parked until the owed seq-0 snapshot applies,
    /// the binding is torn down, or their own `snapshotTimeout` deadline.
    @ObservationIgnored var snapshotWaiters: [UUID: CheckedContinuation<Void, Never>] = [:]
    /// A registration's seq-0 snapshot is owed: raised by `subscribe`, held
    /// across rejection, timeout, retry and reconnect (each re-registers for
    /// the same binding), cleared when a snapshot applies or the binding is
    /// torn down.
    @ObservationIgnored var snapshotPending = false
    /// The channel applied a snapshot and owns the streaming flag; while it
    /// is false (no channel yet, rejected registration, reconnect), the
    /// content-free `agent:stream:*` firehose is the only liveness signal.
    var chatLive = false
    @ObservationIgnored var chatSubscriptionId: String?
    var chatChannelActive = false
    var chatSeeded = false
    private var chatExpectedSeq = 0
    /// Registration whose gap / rejected-empty-snapshot recovery is scheduled
    /// or in flight. Recovery is owned per registration: it validates this
    /// token before every mutation and after every suspension, and the token
    /// stops matching the moment a newer registration (its own replacement
    /// included), `reset` or reconnect advances `registrationGeneration`, so
    /// a superseded recovery can neither touch the newer channel nor block
    /// its own recovery.
    @ObservationIgnored var recoveryGeneration: Int?
    var resnapshotInProgress: Bool {
        recoveryGeneration == registrationGeneration
    }
    /// One rejected empty snapshot gets a replacement subscription. If that
    /// replacement also reports empty after recovery completes, accept it as
    /// an authoritative deletion instead of resubscribing without a bound.
    @ObservationIgnored var emptySnapshotRecoveryAttempts = 0
    private let timestampFormatter = ISO8601DateFormatter()
    @ObservationIgnored private var hydratedBlocks: [String: ContentBlock] = [:]
    @ObservationIgnored private var hydratedBlockOrder: [String] = []

    private static let maxHydratedBlocks = 30
    private static let maxEmptySnapshotRecoveryAttempts = 1
    private static let defaultSnapshotTimeoutSeconds = 5
    private static let defaultInitialRetryDelaySeconds = 1
    private static let defaultMaxRetryDelaySeconds = 30
    static let defaultSnapshotTimeout: Duration = .seconds(defaultSnapshotTimeoutSeconds)
    static let defaultInitialRetryDelay: Duration = .seconds(defaultInitialRetryDelaySeconds)
    static let defaultMaxRetryDelay: Duration = .seconds(defaultMaxRetryDelaySeconds)

    init(connectionManager: ConnectionManagerRouting) {
        self.connectionManager = connectionManager
    }

    isolated deinit {
        if let subscriptionId = chatSubscriptionId {
            connectionManager.unregisterSubscriptionHandler(id: subscriptionId)
            Self.release(subscriptionId, via: connectionManager)
        }
        snapshotTimeoutTask?.cancel()
        retryTask?.cancel()
        for waiter in snapshotWaiters.values {
            waiter.resume()
        }
    }
}

extension ConversationLiveTranscript {
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
                        "blockId": blockId
                    ]
                )
                return await Self.decodeMessageBlock(InboundJSONValue(value: result), blockId: blockId)
            }
            guard let decoded else { return }
            guard let block = decoded else {
                AppLog.conversation.error(
                    "[ConversationStore] getMessageBlock returned no decodable block for \(key)"
                )
                return
            }
            storeHydratedBlock(block, forKey: key)
            remergeHydratedBlocks()
        } catch {
            AppLog.conversation.error(
                "[ConversationStore] Failed to hydrate block \(key): \(error)"
            )
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

    func remergeHydratedBlocks() {
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

    func setTestChannel(subscriptionId: String) {
        chatChannelActive = true
        chatSeeded = false
        chatSubscriptionId = subscriptionId
    }

    func handlePush(_ push: SubscriptionPush) {
        guard chatChannelActive, let subscriptionId = chatSubscriptionId,
              push.subscriptionId == subscriptionId else { return }

        switch push.kind {
        case .snapshot:
            if chatSeeded, push.seq + 1 < chatExpectedSeq { return }
            applySnapshot(push)
        case .delta:
            guard let delta = push.delta else { return }
            if chatSeeded, push.seq == chatExpectedSeq {
                applyDelta(delta)
                chatExpectedSeq = push.seq + 1
            } else if chatSeeded, push.seq < chatExpectedSeq {
                return
            } else if !resnapshotInProgress {
                AppLog.conversation.warning(
                    "[ConversationStore] Chat sequence gap detected at seq=\(push.seq), resubscribing..."
                )
                scheduleResnapshot()
            }
        }
    }

    /// Schedules recovery for the current registration; the token is taken
    /// here, so a registration opened before the work runs supersedes it.
    private func scheduleResnapshot() {
        let generation = registrationGeneration
        recoveryGeneration = generation
        Task { [weak self] in await self?.resnapshot(for: generation) }
    }

    private func applySnapshot(_ push: SubscriptionPush) {
        guard let items = push.snapshot else { return }
        let snapshotMessages = push.snapshotMessages ?? ConversationMessage.parseMessages(items)
        if snapshotMessages.isEmpty, !messages.isEmpty {
            if emptySnapshotRecoveryAttempts >= Self.maxEmptySnapshotRecoveryAttempts,
               !resnapshotInProgress {
                AppLog.conversation.warning(
                    "[ConversationStore] Accepting repeated empty chat snapshot after recovery"
                )
                emptySnapshotRecoveryAttempts = 0
            } else {
                AppLog.conversation.warning(
                    "[ConversationStore] Rejecting empty chat snapshot over populated transcript, resubscribing..."
                )
                // The registration answered; only its content is in doubt.
                resumeSnapshotWaiters()
                if !resnapshotInProgress {
                    emptySnapshotRecoveryAttempts += 1
                    scheduleResnapshot()
                }
                return
            }
        } else if !snapshotMessages.isEmpty {
            emptySnapshotRecoveryAttempts = 0
        }
        chatLive = true
        chatSeeded = true
        snapshotPending = false
        chatExpectedSeq = push.seq + 1
        liveStateVersion &+= 1
        resetBackoff()
        // `parse` pre-decodes off MainActor; the fallback covers pushes built
        // directly from raw dictionaries (tests).
        messages = snapshotMessages
        remergeHydratedBlocks()

        isTruncated = push.snapshotMeta?["truncated"] as? Bool ?? false
        totalMessageCount = push.snapshotMeta?["totalMessages"] as? Int ?? messages.count
        let hasInFlightMessage = messages.contains { $0.isStreaming == true }
        let isResponding = push.snapshotMeta?["isResponding"] as? Bool ?? false
        let turnInFlight = push.snapshotMeta?["turnInFlight"] as? Bool ?? false
        isStreaming = hasInFlightMessage || isResponding || turnInFlight
        AppLog.conversation.debug(
            "[ConversationStore] Applied chat snapshot with \(items.count) messages, "
                + "seq=\(push.seq), streaming=\(isStreaming)"
        )
        isLoading = false
        resumeSnapshotWaiters()
        onTranscriptReplaced?()
    }

    private func applyDelta(_ delta: SubscriptionPush.DeltaPayload) {
        liveStateVersion &+= 1
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
        if !entities.isEmpty || !delta.removedIds.isEmpty {
            emptySnapshotRecoveryAttempts = 0
        }

        if sawTerminal {
            isStreaming = false
            streamingUpdateCount = 0
        } else if sawUpsert {
            isStreaming = true
            streamingUpdateCount += 1
        }
        AppLog.conversation.debug(
            "[ConversationStore] Applied chat delta, added=\(delta.added.count), "
                + "updated=\(delta.updated.count), removed=\(delta.removedIds.count), "
                + "terminal=\(sawTerminal)"
        )
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
        registrationGeneration &+= 1
        hydratingBlockKeys = []
        hydratedBlocks = [:]
        hydratedBlockOrder = []
        chatLive = false
        releaseActiveRegistration()
        chatChannelActive = false
        chatSeeded = false
        snapshotPending = false
        chatExpectedSeq = 0
        recoveryGeneration = nil
        emptySnapshotRecoveryAttempts = 0
        resetBackoff()
        resumeSnapshotWaiters()
    }
}
