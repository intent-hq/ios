import Foundation
import Observation

nonisolated struct InboundJSONValue: @unchecked Sendable {
    let value: Any
}

@MainActor
@Observable
final class ConversationLiveTranscript {
    var messages: [ConversationMessage] = [] {
        didSet { messageIDsNeedRefresh = true }
    }
    @ObservationIgnored private var cachedMessageIDs: Set<String> = []
    @ObservationIgnored private var messageIDsNeedRefresh = true

    var messageIDs: Set<String> {
        _ = messages
        if messageIDsNeedRefresh {
            let updatedIDs = Set(messages.lazy.map(\.id))
            if updatedIDs != cachedMessageIDs { cachedMessageIDs = updatedIDs }
            messageIDsNeedRefresh = false
        }
        return cachedMessageIDs
    }

    var isStreaming = false {
        didSet {
            guard oldValue != isStreaming else { return }
            onStreamingChanged?(isStreaming)
        }
    }
    var isLoading = false {
        didSet {
            guard oldValue != isLoading else { return }
            traceEvent("LoadState", "loading=\(isLoading) seeded=\(chatSeeded) messages=\(messages.count)")
        }
    }
    var subscriptionLoadingStage: LoadingStage = .requesting {
        didSet {
            guard oldValue != subscriptionLoadingStage else { return }
            traceEvent("LoadStage", "stage=\(subscriptionLoadingStage) attempt=\(subscriptionAttempt)")
        }
    }
    @ObservationIgnored var subscriptionAttempt = 0
    var streamingUpdateCount = 0
    var isTruncated = false
    var totalMessageCount = 0
    var hydratingBlockKeys: Set<String> = []
    var olderMessagesCursor: String?
    var hasOlderMessages: Bool { olderMessagesCursor != nil }
    var isLoadingOlderMessages = false
    var olderMessagesError: String?
    @ObservationIgnored var olderHistoryGeneration = 0
    @ObservationIgnored var olderHistorySeeded = false

    @ObservationIgnored var onStreamingChanged: (@MainActor (Bool) -> Void)?
    @ObservationIgnored var onSubscribeError: (@MainActor (Error) -> Void)?
    @ObservationIgnored var onTranscriptReplaced: (@MainActor () -> Void)?
    @ObservationIgnored var onAuthoritativeMessages: (@MainActor ([ConversationMessage], Bool) -> Void)?

    let connectionManager: ConnectionManagerRouting
    var agentId: String?
    var workspaceId: String?
    @ObservationIgnored var bindingGeneration = 0
    @ObservationIgnored var registrationGeneration = 0
    @ObservationIgnored var liveStateVersion = 0
    @ObservationIgnored var snapshotTimeout = ConversationLiveTranscript.defaultSnapshotTimeout
    @ObservationIgnored var initialRetryDelay = ConversationLiveTranscript.defaultInitialRetryDelay
    @ObservationIgnored var maxRetryDelay = ConversationLiveTranscript.defaultMaxRetryDelay
    @ObservationIgnored var nextRetryDelay: Duration?
    @ObservationIgnored var snapshotTimeoutTask: Task<Void, Never>?
    @ObservationIgnored var retryTask: Task<Void, Never>?
    @ObservationIgnored var snapshotWaiters: [UUID: CheckedContinuation<Void, Never>] = [:]
    @ObservationIgnored var snapshotPending = false // swiftlint:disable:this state_phase_flag

    enum ChatChannel: Equatable {
        case inactive
        case registering
        case live
    }

    var chatChannel = ChatChannel.inactive {
        didSet {
            guard oldValue != chatChannel else { return }
            traceEvent("ChatChannel", "state=\(chatChannel) messages=\(messages.count)")
        }
    }
    @ObservationIgnored var chatSubscriptionId: String?
    var chatChannelActive: Bool { chatChannel != .inactive }
    var chatLive: Bool { chatChannel == .live }
    var chatSeeded: Bool { chatLive }
    @ObservationIgnored var incrementalDeltas = false
    @ObservationIgnored var useFullDeltaEncoding = false
    private var chatExpectedSeq = 0
    @ObservationIgnored var recoveryGeneration: Int?
    var resnapshotInProgress: Bool {
        recoveryGeneration == registrationGeneration
    }
    @ObservationIgnored var emptySnapshotRecoveryAttempts = 0
    private let timestampFormatter = ISO8601DateFormatter()
    @ObservationIgnored var hydratedBlocks: [String: ContentBlock] = [:]
    @ObservationIgnored var hydratedBlockOrder: [String] = []

    static let maxHydratedBlocks = 30
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
    func setTestChannel(subscriptionId: String) {
        chatChannel = .registering
        incrementalDeltas = false
        chatSubscriptionId = subscriptionId
    }

    func handlePush(_ push: SubscriptionPush) {
        guard chatChannelActive, let subscriptionId = chatSubscriptionId,
              push.subscriptionId == subscriptionId else {
            traceEvent("ChatPushRejected", "reason=inactive_channel seq=\(push.seq)")
            return
        }

        switch push.kind {
        case .snapshot:
            if chatSeeded, push.seq + 1 < chatExpectedSeq {
                traceEvent("ChatSnapshotRejected", "reason=stale_sequence seq=\(push.seq) expected=\(chatExpectedSeq)")
                return
            }
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

    private func scheduleResnapshot() {
        let generation = registrationGeneration
        recoveryGeneration = generation
        Task { [weak self] in await self?.resnapshot(for: generation) }
    }

    private func applySnapshot(_ push: SubscriptionPush) {
        guard let items = push.snapshot else {
            traceEvent("ChatSnapshotRejected", "reason=missing_payload seq=\(push.seq)")
            return
        }
        let interval = ConversationTrace.begin("ChatSnapshotApply", "\(traceContext) seq=\(push.seq)")
        var accepted = false
        defer { ConversationTrace.end("ChatSnapshotApply", interval, "\(traceContext) accepted=\(accepted)") }
        let snapshotMessages = push.snapshotMessages ?? ConversationMessage.parseMessages(items)
        let resumed = push.snapshotMeta?["resumed"] as? Bool == true
        traceEvent(
            "ChatSnapshotReceived",
            "seq=\(push.seq) items=\(items.count) messages=\(snapshotMessages.count) blocks=\(snapshotMessages.reduce(0) { $0 + $1.contentBlocks.count }) predecoded=\(push.snapshotMessages != nil) resumed=\(resumed)"
        )
        guard shouldAcceptSnapshot(snapshotMessages, resumed: resumed) else { return }
        chatChannel = .live
        incrementalDeltas = push.snapshotMeta?["deltaEncoding"] as? String == "incremental"
        snapshotPending = false
        chatExpectedSeq = push.seq + 1
        liveStateVersion &+= 1
        resetBackoff()
        replaceHistory(with: snapshotMessages, metadata: push.snapshotMeta ?? [:])
        discardHydratedText(in: snapshotMessages)
        remergeHydratedBlocks()

        totalMessageCount = push.snapshotMeta?["totalMessages"] as? Int ?? messages.count
        let hasInFlightMessage = snapshotMessages.contains { $0.isStreaming == true }
        let isResponding = push.snapshotMeta?["isResponding"] as? Bool ?? false
        let turnInFlight = push.snapshotMeta?["turnInFlight"] as? Bool ?? false
        isStreaming = hasInFlightMessage || isResponding || turnInFlight
        AppLog.conversation.debug(
            "[ConversationStore] Applied chat snapshot with \(items.count) messages, "
                + "seq=\(push.seq), streaming=\(isStreaming)"
        )
        isLoading = false
        accepted = true
        traceEvent(
            "ChatSnapshotAccepted",
            "seq=\(push.seq) incoming=\(snapshotMessages.count) resident=\(messages.count) blocks=\(messages.reduce(0) { $0 + $1.contentBlocks.count }) "
                + "total=\(totalMessageCount) streaming=\(isStreaming) loading=\(isLoading) seeded=\(chatSeeded)"
        )
        resumeSnapshotWaiters()
        onAuthoritativeMessages?(snapshotMessages, true)
        onTranscriptReplaced?()
    }

    private func shouldAcceptSnapshot(_ snapshotMessages: [ConversationMessage], resumed: Bool) -> Bool {
        if !resumed, snapshotMessages.isEmpty, !messages.isEmpty {
            if emptySnapshotRecoveryAttempts >= Self.maxEmptySnapshotRecoveryAttempts,
               !resnapshotInProgress {
                AppLog.conversation.warning(
                    "[ConversationStore] Accepting repeated empty chat snapshot after recovery"
                )
                emptySnapshotRecoveryAttempts = 0
            } else {
                traceEvent("ChatSnapshotRejected", "reason=empty_over_existing recoveryAttempts=\(emptySnapshotRecoveryAttempts)")
                AppLog.conversation.warning(
                    "[ConversationStore] Rejecting empty chat snapshot over populated transcript, resubscribing..."
                )
                resumeSnapshotWaiters()
                if !resnapshotInProgress {
                    emptySnapshotRecoveryAttempts += 1
                    scheduleResnapshot()
                }
                return false
            }
        } else if !snapshotMessages.isEmpty {
            emptySnapshotRecoveryAttempts = 0
        }
        return true
    }

    private func applyDelta(_ delta: SubscriptionPush.DeltaPayload) {
        liveStateVersion &+= 1
        var sawTerminal = false
        var sawUpsert = false
        let entities = (delta.chatBlocks ?? SubscriptionPush.ChatBlockEntity.decodeAll(delta.added + delta.updated))
            .filter { $0.textDelta == nil || incrementalDeltas }
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
        let incomingUserIds = Set(entities.filter { $0.role == .user }.map(\.messageId))
        onAuthoritativeMessages?(
            messages.filter { incomingUserIds.contains($0.id) && $0.role == .user },
            sawUpsert || sawTerminal
        )
        onTranscriptReplaced?()
    }

    private func upsertBlock(_ entity: SubscriptionPush.ChatBlockEntity) -> (applied: Bool, terminal: Bool) {
        let messageId = entity.messageId
        var block = entity.block
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
        if let appMessageId = entity.appMessageId {
            messages[messageIndex].appMessageId = appMessageId
        }
        if !entity.metadata.isEmpty, entity.metadata != messages[messageIndex].metadata {
            messages[messageIndex].metadata = entity.metadata
        }
        var blocks = messages[messageIndex].contentBlocks
        if let fragment = entity.textDelta {
            let prior = blocks.first { $0.id == block.id }
            block.text = (prior?.resolvedText ?? "") + fragment
        }
        discardHydratedText(block, messageId: messageId)
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
        resetOlderHistory()
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
        releaseActiveRegistration()
        chatChannel = .inactive
        incrementalDeltas = false
        useFullDeltaEncoding = false
        snapshotPending = false
        chatExpectedSeq = 0
        recoveryGeneration = nil
        emptySnapshotRecoveryAttempts = 0
        resetBackoff()
        resumeSnapshotWaiters()
    }
}
