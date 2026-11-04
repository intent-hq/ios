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

    /// Geometry callbacks share one membership snapshot until messages change.
    /// Invalidate at the array owner so queued callbacks see deletions even
    /// before SwiftUI's onChange runs, including same-count replacements.
    var messageIDs: Set<String> {
        _ = messages // Keep cached reads observable to SwiftUI consumers.
        if messageIDsNeedRefresh {
            let updatedIDs = Set(messages.lazy.map(\.id))
            // Retain shared Set storage on content-only edits so consumers'
            // equality guards stay constant-time on subsequent geometry ticks.
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
    /// Fired when `chat.subscribe` is rejected for the still-bound agent.
    @ObservationIgnored var onSubscribeError: (@MainActor (Error) -> Void)?
    /// Fired after the live chat channel replaced (snapshot) or merged (delta)
    /// the transcript, so the owner can reconcile state keyed on row residency.
    @ObservationIgnored var onTranscriptReplaced: (@MainActor () -> Void)?
    /// Only incoming server rows, never the merged array containing optimistic
    /// local rows. A delta about another message cannot confirm a local send.
    @ObservationIgnored var onAuthoritativeMessages: (@MainActor ([ConversationMessage], Bool) -> Void)?

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

    enum ChatChannel: Equatable {
        /// No registration: before the first subscribe, after a rejection,
        /// reconnect or reset.
        case inactive
        /// A registration is open (requested or acked) and its seq-0 snapshot
        /// has not applied yet.
        case registering
        /// A snapshot applied: the channel owns the transcript and streaming flag.
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
    /// While false (no channel yet, rejected registration, reconnect), the
    /// content-free `agent:stream:*` firehose is the only liveness signal.
    var chatLive: Bool { chatChannel == .live }
    var chatSeeded: Bool { chatLive }
    /// Only the latest accepted snapshot can enable fragment appends.
    @ObservationIgnored var incrementalDeltas = false
    /// A known encoding-parameter rejection is remembered for this connection;
    /// reconnect/reset clears it so a changed daemon can negotiate again.
    @ObservationIgnored var useFullDeltaEncoding = false
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

    /// Schedules recovery for the current registration; the token is taken
    /// here, so a registration opened before the work runs supersedes it.
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
        // `parse` pre-decodes off MainActor; the fallback covers pushes built
        // directly from raw dictionaries (tests).
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
                // The registration answered; only its content is in doubt.
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
