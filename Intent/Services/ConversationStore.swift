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
    private static let defaultStreamEventBufferMaxEvents = 512
    private static let defaultStreamEventBufferMaxBytes = 2 * 1024 * 1024 // swiftlint:disable:this no_magic_numbers
    /// Aggregate retention ceiling for `streamEventBuffer` while the initial
    /// `agent.getConversation` is in flight (ios#380). Exceeding either bound
    /// marks the buffered replay lossy — see `replayBufferedStreamEvents`.
    static let defaultStreamEventBufferBudget = StreamEventBufferBudget(
        maxEvents: defaultStreamEventBufferMaxEvents,
        maxBytes: defaultStreamEventBufferMaxBytes
    )

    var messages: [ConversationMessage] {
        get { liveTranscript.messages }
        set { liveTranscript.messages = newValue }
    }
    @ObservationIgnored var onStreamingChanged: ((Bool) -> Void)?
    var isStreaming: Bool {
        get { liveTranscript.isStreaming }
        set { liveTranscript.isStreaming = newValue }
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
    var attentionRequest: PendingAttentionRequest?
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
    var agentId: String?
    var workspaceId: String?
    var subscriptionId: String?
    var connectionObserver: AnyCancellable?
    var currentStreamId: String?
    var isSubscribing = false
    @ObservationIgnored var eventHandlerId: UUID?
    var streamEventBuffer: [(eventType: String, data: [String: Any])] = []
    @ObservationIgnored var streamEventBufferBudget = ConversationStore.defaultStreamEventBufferBudget
    @ObservationIgnored var streamEventBufferBytes = 0
    /// Set when a burst exceeded `streamEventBufferBudget` during the load
    /// window: the retained events are no longer a complete record, so the
    /// replay reconciles from the daemon instead of applying them.
    @ObservationIgnored var streamEventBufferOverflowed = false
    @ObservationIgnored var sessionMetadataGeneration = 0
    @ObservationIgnored var pendingQuestionRecoveryTask: Task<Void, Never>?
    @ObservationIgnored var markedQuestionRetryDelays: [Duration] =
        ConversationStore.defaultMarkedQuestionRetryDelays
    var lastFailedSend: (messageId: String, content: String)?
    var hydratingBlockKeys: Set<String> {
        get { liveTranscript.hydratingBlockKeys }
        set { liveTranscript.hydratingBlockKeys = newValue }
    }

    init(connectionManager: ConnectionManagerRouting = ConnectionManager.shared) {
        let commands = ConversationCommands(connectionManager: connectionManager)
        self.connectionManager = connectionManager
        self.commands = commands
        self.watchedAgentCoordinator = ConversationWatchedAgents(commands: commands)
        self.liveTranscript = ConversationLiveTranscript(connectionManager: connectionManager)
        liveTranscript.onStreamingChanged = { [weak self] isStreaming in
            self?.onStreamingChanged?(isStreaming)
        }
        liveTranscript.onInitialLoadCompleted = { [weak self] in
            self?.replayBufferedStreamEvents()
        }
        liveTranscript.onFetchError = { [weak self] error in
            self?.raiseAgentNotFoundIfDefinitive(error)
        }
        liveTranscript.onTranscriptReplaced = { [weak self] in
            self?.reconcilePendingQuestionRecovery()
        }
        observeConnection()
    }

    isolated deinit {
        if let handlerId = eventHandlerId {
            connectionManager.removeEventHandler(id: handlerId)
        }
    }
}

struct StreamEventBufferBudget: Equatable {
    let maxEvents: Int
    let maxBytes: Int
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
