import Combine
import Foundation
import SwiftUI

@MainActor
@Observable class ConversationStore {
    static let invalidParametersErrorCode = -32_602
    private static let initialMarkedRetryDelayMilliseconds = 250
    private static let finalMarkedRetryDelayMilliseconds = 1000
    private static let defaultMarkedQuestionRetryDelays: [Duration] = [
        .milliseconds(initialMarkedRetryDelayMilliseconds),
        .milliseconds(finalMarkedRetryDelayMilliseconds)
    ]

    var messages: [ConversationMessage] {
        get { liveTranscript.messages }
        set { liveTranscript.messages = newValue }
    }
    var isStreaming: Bool {
        get { liveTranscript.isStreaming || !sendThinkingMessageIds.isEmpty }
        set {
            liveTranscript.isStreaming = newValue
            sendThinkingMessageIds.removeAll()
        }
    }
    var isLoading: Bool {
        get { liveTranscript.isLoading }
        set { liveTranscript.isLoading = newValue }
    }
    var queuedMessages: [QueuedMessage] {
        get { commands.queuedMessages }
        set { commands.queuedMessages = newValue }
    }
    var streamingUpdateCount: Int {
        get { liveTranscript.streamingUpdateCount }
        set { liveTranscript.streamingUpdateCount = newValue }
    }
    var watchedAgentIds: [String] {
        get { watchedAgentCoordinator.watchedAgentIds }
        set { watchedAgentCoordinator.watchedAgentIds = newValue }
    }
    var delegationGroupStatus: (completed: Int, total: Int)? {
        get { watchedAgentCoordinator.delegationGroupStatus }
        set { watchedAgentCoordinator.delegationGroupStatus = newValue }
    }
    var isWaitingForAgents: Bool {
        get { watchedAgentCoordinator.isWaitingForAgents }
        set { watchedAgentCoordinator.isWaitingForAgents = newValue }
    }
    var watchedAgents: [AgentSession] {
        get { watchedAgentCoordinator.watchedAgents }
        set { watchedAgentCoordinator.watchedAgents = newValue }
    }
    var isTruncated: Bool {
        get { liveTranscript.isTruncated }
        set { liveTranscript.isTruncated = newValue }
    }
    var totalMessageCount: Int {
        get { liveTranscript.totalMessageCount }
        set { liveTranscript.totalMessageCount = newValue }
    }
    var hasOlderMessages: Bool { liveTranscript.hasOlderMessages }
    var isLoadingOlderMessages: Bool { liveTranscript.isLoadingOlderMessages }
    var olderMessagesError: String? { liveTranscript.olderMessagesError }

    func loadOlderMessages() async {
        await liveTranscript.loadOlderMessages(using: commands)
    }

    var agentNotFound = false
    var pendingQuestionsMessageId: String? {
        get { commands.pendingQuestionsMessageId }
        set { commands.pendingQuestionsMessageId = newValue }
    }
    var dismissedQuestionsMessageId: String? {
        get { commands.dismissedQuestionsMessageId }
        set { commands.dismissedQuestionsMessageId = newValue }
    }
    var lastSeenMessageId: String? {
        get { commands.lastSeenMessageId }
        set { commands.lastSeenMessageId = newValue }
    }
    var pendingQuestionRecovery: PendingQuestionRecovery?

    let connectionManager: ConnectionManagerRouting
    @ObservationIgnored let liveTranscript: ConversationLiveTranscript
    @ObservationIgnored let commands: ConversationCommands
    @ObservationIgnored let watchedAgentCoordinator: ConversationWatchedAgents
    var agentId: String? {
        didSet {
            if agentId != oldValue { liveTranscript.resetOlderHistory() }
        }
    }
    var workspaceId: String?
    @ObservationIgnored var bootstrapWorkspaceHint: String?

    struct PendingWorkspaceEvent {
        let event: [String: Any]
        let receivedAt: Int
        let confirmedMarkerRevisions: [String: Int]
    }

    @ObservationIgnored var pendingWorkspaceEvents: [PendingWorkspaceEvent] = []
    @ObservationIgnored var isFoldingWorkspaceEvents = false
    @ObservationIgnored var workspaceAuthorityWaiters: [UUID: CheckedContinuation<Bool, Never>] = [:]
    @ObservationIgnored var workspaceAuthorityFailed = false
    @ObservationIgnored var subscriptionsNeedAuthorityRecovery = false
    var connectionObserver: AnyCancellable?
    @ObservationIgnored var feedObserver: AnyCancellable?
    @ObservationIgnored var observedConnectionState: ConnectionState
    @ObservationIgnored var bootstrapTask: Task<Void, Never>?
    @ObservationIgnored var bootstrapGeneration = 0
    @ObservationIgnored var needsFeedReconciliation = false
    var metadataReadyForEntry = false
    @ObservationIgnored var consumers: Set<UUID> = []
    @ObservationIgnored var streamingObservers: [UUID: (Bool) -> Void] = [:]
    @ObservationIgnored var entryObservers: [UUID: () -> Void] = [:]
    @ObservationIgnored var queueReadTask: Task<Void, Never>?
    @ObservationIgnored var queueReadPending = false
    @ObservationIgnored var queueRefreshQueued = false
    @ObservationIgnored var subscriptionReadTask: Task<Void, Never>?
    @ObservationIgnored var subscriptionRefreshQueued = false
    @ObservationIgnored var subscriptionRevision = 0

    @ObservationIgnored var eventHandlerId: UUID?
    var sessionMetadataGeneration = 0
    @ObservationIgnored var agentBindingGeneration = 0
    @ObservationIgnored var eventRegistrationGeneration = 0
    @ObservationIgnored var streamingEventsActive = false
    @ObservationIgnored var metadataRefreshTasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored var pendingQuestionRecoveryTask: Task<Void, Never>?
    @ObservationIgnored var markedQuestionRetryDelays: [Duration] =
        ConversationStore.defaultMarkedQuestionRetryDelays
    var sendAttempts: [ConversationSendAttempt] = []
    var lastFailedSend: ConversationSendAttempt? {
        sendAttempts.last { $0.status.needsRecovery }
    }
    var sendThinkingMessageIds: Set<String> = [] {
        didSet {
            let wasStreaming = liveTranscript.isStreaming || !oldValue.isEmpty
            if wasStreaming != isStreaming { notifyStreamingChanged() }
        }
    }
    var hydratingBlockKeys: Set<String> {
        get { liveTranscript.hydratingBlockKeys }
        set { liveTranscript.hydratingBlockKeys = newValue }
    }

    init(connectionManager: ConnectionManagerRouting = ConnectionManager.shared, agentDetails: AgentDetailStore? = nil) {
        let commands = ConversationCommands(connectionManager: connectionManager, agentDetails: agentDetails)
        self.connectionManager = connectionManager
        self.observedConnectionState = connectionManager.connectionState
        self.commands = commands
        self.watchedAgentCoordinator = ConversationWatchedAgents(commands: commands)
        self.liveTranscript = ConversationLiveTranscript(connectionManager: connectionManager)
        liveTranscript.onStreamingChanged = { [weak self] _ in
            guard let self else { return }
            notifyStreamingChanged()
        }
        liveTranscript.onSubscribeError = { [weak self] error in
            self?.raiseAgentNotFoundIfDefinitive(error)
        }
        liveTranscript.onTranscriptReplaced = { [weak self] in
            self?.reconcilePendingQuestionRecovery()
            self?.notifyEntryStateChanged()
        }
        liveTranscript.onAuthoritativeMessages = { [weak self] messages, hasActivityState in
            // A user-row delta confirms delivery, not the end of a turn.
            // Only a snapshot or assistant activity replaces optimistic Thinking.
            if hasActivityState { self?.sendThinkingMessageIds.removeAll() }
            self?.reconcileSendAttempts(messages: messages)
        }
        commands.onQueueSnapshot = { [weak self] queue in
            self?.reconcileSendAttempts(queue: queue)
        }
        observeConnection()
    }

    isolated deinit {
        for task in metadataRefreshTasks.values { task.cancel() }
        if let handlerId = eventHandlerId {
            connectionManager.removeEventHandler(id: handlerId)
        }
        bootstrapTask?.cancel()
        queueReadTask?.cancel()
        subscriptionReadTask?.cancel()
    }
}

struct PendingQuestionRecovery {
    enum Status: Equatable {
        case loading
        case found
        case notFound
        case error
    }

    let messageId: String
    let status: Status
    let message: ConversationMessage?

    init(messageId: String, status: Status, message: ConversationMessage? = nil) {
        self.messageId = messageId
        self.status = status
        self.message = message
    }
}
