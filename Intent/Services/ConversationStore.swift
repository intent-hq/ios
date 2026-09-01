import Combine
import Foundation
import SwiftUI

@MainActor
@Observable class ConversationStore {
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
    /// Pending attention request for OUR agent (PROTOCOL §5.5), refreshed from
    /// `agent.get`. The daemon clears the underlying fields when the agent next
    /// receives a message, so this retires via the same refresh.
    var attentionRequest: PendingAttentionRequest?
    /// True when the daemon has definitively told us our agent does not exist —
    /// a `-32602` with `data.code == "not-found"` on
    /// `agent.getConversation`/`agent.get`, or an `agent:deleted` event for the
    /// open agent. Transient transport errors never raise this. The view
    /// observes it to fall back to the agent list.
    var agentNotFound = false
    /// The question-dismissal marker (PROTOCOL §5.5): id of the question-bearing
    /// assistant message the user dismissed via `agent.dismissQuestions`.
    /// Daemon-persisted in session metadata (survives restarts); refreshed from
    /// `agent.get` and updated push-style by `agent:updated`. The wizard gate
    /// retires a pending set whose message id matches it.
    var dismissedQuestionsMessageId: String? {
        get { commands.dismissedQuestionsMessageId }
        set { commands.dismissedQuestionsMessageId = newValue }
    }
    /// The per-conversation seen marker (PROTOCOL §5.5, v4.5): id of the newest
    /// transcript message the user has seen, advanced via `agent.markSeen`.
    /// Daemon-persisted in session metadata (survives restarts); refreshed from
    /// `agent.get` and updated push-style by `agent:updated` so marker moves
    /// from other clients converge here too.
    var lastSeenMessageId: String? {
        get { commands.lastSeenMessageId }
        set { commands.lastSeenMessageId = newValue }
    }

    private let connectionManager: ConnectionManagerRouting
    @ObservationIgnored private let liveTranscript: ConversationLiveTranscript
    @ObservationIgnored private let commands: ConversationCommands
    @ObservationIgnored private let watchedAgentCoordinator: ConversationWatchedAgents
    private var agentId: String?
    private var workspaceId: String?
    private var subscriptionId: String?
    private var connectionObserver: AnyCancellable?
    private var currentStreamId: String?
    private var isSubscribing = false
    @ObservationIgnored private var eventHandlerId: UUID?
    /// Buffer for stream events that arrive while the initial conversation fetch is in progress.
    /// This prevents lost deltas when subscribing before fetching.
    private var streamEventBuffer: [(eventType: String, data: [String: Any])] = []

    /// Tracks the last failed send so retrying the same content reuses the messageId
    /// (preventing duplicate messages on the server).
    var lastFailedSend: (messageId: String, content: String)?

    /// Block keys (`{messageId}|{blockId}`) with an `agent.getMessageBlock`
    /// hydration fetch in flight (slim projection, PROTOCOL §5.5). Observed so
    /// the transcript can show a per-block loading affordance.
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
        observeConnection()
    }

    isolated deinit {
        if let handlerId = eventHandlerId {
            connectionManager.removeEventHandler(id: handlerId)
        }
    }

    /// Test-only helper: activate the chat channel and set its subscriptionId,
    /// bypassing the real subscribe flow, so the strict push gate accepts test payloads.
    func setTestChatChannel(subscriptionId: String) {
        liveTranscript.setTestChannel(subscriptionId: subscriptionId)
    }

    // MARK: - Connection observation

    private func observeConnection() {
        connectionObserver = connectionManager.connectionStatePublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                if state == .connected {
                    Task { await self?.onReconnected() }
                }
            }
    }

    private func onReconnected() async {
        liveTranscript.prepareForReconnect()

        // Re-fetch conversation on reconnection
        guard let agentId = agentId else { return }
        // Parallel fetch of independent data
        async let conv: () = fetchConversation(agentId: agentId, workspaceId: workspaceId)
        async let queue: () = fetchQueue(agentId: agentId)
        // Restore authoritative streaming state from the server
        async let streaming: () = fetchAgentStreamingState(agentId: agentId)
        _ = await (conv, queue, streaming)
        if let workspaceId = workspaceId {
            await subscribeToStreaming(agentId: agentId, workspaceId: workspaceId)
            await subscribeLiveChat(agentId: agentId)
            await fetchSubscriptions(agentId: agentId, workspaceId: workspaceId)
        }
    }

    /// Fetch the agent's current state via `agent.get` and restore `isStreaming`.
    /// Considers the STAB-125 `turnInFlight` turn-liveness flag alongside
    /// `isStreaming`/`isResponding` (the headless daemon reports liveness via
    /// `turnInFlight`; `isStreaming`/`isResponding` may always be false).
    /// With `raiseOnly` the flag is only ever raised, never cleared — used as a
    /// backstop on view load so it cannot clobber snapshot/optimistic state.
    /// The pending attention request is always taken from the server response
    /// (raise or clear) — it is server-authoritative with no optimistic state.
    func fetchAgentStreamingState(agentId: String, raiseOnly: Bool = false) async {
        do {
            if let state = try await commands.fetchAgentState(agentId: agentId) {
                if raiseOnly {
                    if state.isStreaming { isStreaming = true }
                } else {
                    isStreaming = state.isStreaming
                }
                attentionRequest = state.attentionRequest
                if let dismissedId = state.dismissedQuestionsMessageId {
                    dismissedQuestionsMessageId = dismissedId
                }
                if let seenId = state.lastSeenMessageId { lastSeenMessageId = seenId }
            }
        } catch {
            raiseAgentNotFoundIfDefinitive(error)
            AppLog.conversation.error("[ConversationStore] Failed to fetch agent streaming state: \(error)")
        }
    }

    /// Raise `agentNotFound` only for a definitive not-found JSON-RPC error
    /// (`-32602` with `data.code == "not-found"`, PROTOCOL §3.3/§9) — transient
    /// transport errors (timeouts, disconnects) must not read as deletion. Any
    /// other `-32602` (`invalid-params` or absent `data`) is logged loudly and
    /// NOT classified as deletion: a client params bug must not silently
    /// masquerade as a deleted agent.
    private func raiseAgentNotFoundIfDefinitive(_ error: Error) {
        let nsError = error as NSError
        if nsError.isEntityNotFound {
            AppLog.conversation.warning(
                "[ConversationStore] not-found for agent \(agentId ?? "?") — "
                    + "treating as deleted: \(nsError.localizedDescription)")
            agentNotFound = true
        } else if nsError.domain == "WebSocket" && nsError.code == -32602 {
            AppLog.conversation.error(
                "[ConversationStore] UNEXPECTED -32602 without data.code == \"not-found\" for "
                    + "agent \(agentId ?? "?") (data.code: \(nsError.intentErrorDataCode ?? "absent")) — "
                    + "NOT treating as deletion: \(nsError.localizedDescription)")
        }
    }

    // MARK: - Fetch conversation

    func fetchConversation(agentId: String, workspaceId: String? = nil) async {
        self.agentId = agentId
        if let workspaceId = workspaceId {
            self.workspaceId = workspaceId
        }
        await liveTranscript.fetchConversation(agentId: agentId, workspaceId: workspaceId)
    }

    // MARK: - Slim block hydration (agent.getMessageBlock, PROTOCOL §5.5)

    /// Cache key for a hydrated block: owning message id + block id.
    static func hydratedBlockKey(messageId: String, blockId: String) -> String {
        ConversationLiveTranscript.hydratedBlockKey(
            messageId: messageId,
            blockId: blockId
        )
    }

    /// True when this block's full body is already hydrated (cached).
    func isBlockHydrated(messageId: String, blockId: String) -> Bool {
        liveTranscript.isBlockHydrated(messageId: messageId, blockId: blockId)
    }

    /// Block ids of `messageId` with a hydration fetch in flight (for the
    /// per-block loading affordance in the transcript).
    func hydratingBlockIds(forMessage messageId: String) -> Set<String> {
        liveTranscript.hydratingBlockIds(forMessage: messageId)
    }

    /// Fetch the FULL body of a slim-truncated block on demand via
    /// `agent.getMessageBlock` (result: `{ block }`) and merge it back into
    /// the transcript. Single-flight per block key; a hydrated block is never
    /// refetched.
    func hydrateBlock(messageId: String, blockId: String) async {
        await liveTranscript.hydrateBlock(messageId: messageId, blockId: blockId)
    }

    // MARK: - Stream event buffer replay

    /// Replay buffered stream events after the initial fetch completes.
    private func replayBufferedStreamEvents() {
        let buffer = streamEventBuffer
        streamEventBuffer.removeAll()
        guard !buffer.isEmpty else { return }

        // If the chat.subscribe channel went live while events were buffered, the
        // snapshot/deltas already cover this content — discard the firehose buffer.
        if liveTranscript.shouldDiscardBufferedFirehose { return }

        // Replay user message events — these may not be in the fetch snapshot
        // if the message was created after the fetch started.
        // handleUserMessageSent deduplicates, so this is safe.
        for event in buffer where event.eventType == "agent:user-message:sent" {
            handleUserMessageSent(event.data)
        }

        // If the stream ended during loading, the snapshot has the final state
        let hasStreamEnd = buffer.contains { $0.eventType == "agent:stream:end" }
        if hasStreamEnd {
            return
        }

        // Stream is still active — restore streaming state
        for event in buffer where event.eventType == "agent:stream:start" {
            handleStreamStart(event.data)
        }

        // agent:stream:activity pings are content-free — transcript content
        // comes from chat.subscribe / persisted messages. A buffered ping
        // still means the turn is live (we may have missed stream:start).
        if buffer.contains(where: { $0.eventType == "agent:stream:activity" }) {
            isStreaming = true
        }
    }

    // MARK: - Streaming subscription

    func subscribeToStreaming(agentId: String, workspaceId: String) async {
        guard !isSubscribing else { return }
        isSubscribing = true
        defer { isSubscribing = false }

        self.agentId = agentId
        self.workspaceId = workspaceId

        // Unsubscribe any previous server-side subscription to prevent duplicate events
        await unsubscribePrevious()

        // Remove only our previous handler, not everyone else's
        if let handlerId = eventHandlerId {
            connectionManager.removeEventHandler(id: handlerId)
        }

        // Register event handler
        eventHandlerId = connectionManager.onEvent { [weak self] method, params in
            Task { @MainActor [weak self] in
                self?.handleStreamEvent(method, params: params)
            }
        }

        // Subscribe to agent stream events
        do {
            subscriptionId = try await commands.subscribeToEvents(
                agentId: agentId, workspaceId: workspaceId)
            AppLog.conversation.info("[ConversationStore] Subscribed to streaming events")
        } catch {
            AppLog.conversation.error("[ConversationStore] Failed to subscribe: \(error)")
        }
    }

    // MARK: - Live chat subscription

    func subscribeLiveChat(agentId: String) async {
        await liveTranscript.subscribe(agentId: agentId, workspaceId: workspaceId)
    }

    /// Internal (not private) so tests can drive the real ConnectionManager
    /// registration/replay path into the store.
    func handleChatSubscriptionPush(_ push: SubscriptionPush) {
        liveTranscript.handlePush(push)
    }

    /// Unsubscribe the previous server-side event subscription to prevent duplicate event delivery.
    private func unsubscribePrevious() async {
        guard let subId = subscriptionId else { return }
        subscriptionId = nil
        do {
            try await commands.unsubscribeEvents(subscriptionId: subId)
            AppLog.conversation.debug("[ConversationStore] Unsubscribed previous subscription: \(subId)")
        } catch {
            AppLog.conversation.error("[ConversationStore] Failed to unsubscribe: \(error)")
        }
    }

    func handleStreamEvent(_ method: String, params: Any) {
        guard let dict = params as? [String: Any] else { return }

        // Handle subscription.push for live-state chat updates
        if let push = SubscriptionPush.parse(method: method, params: params) {
            handleChatSubscriptionPush(push)
            return
        }

        // Early agent ID filter: skip events not meant for our agent.
        // This is critical when multiple ConversationStore instances exist.
        // Watched-agent (delegate) events are exempt: the switch below handles
        // them and returns before any transcript mutation.
        if let myAgentId = agentId {
            let eventAgentId: String? = {
                if let inner = dict["event"] as? [String: Any] {
                    let d = inner["data"] as? [String: Any] ?? inner
                    return d["agentId"] as? String ?? inner["agentId"] as? String
                }
                let d = dict["data"] as? [String: Any] ?? dict
                return d["agentId"] as? String ?? dict["agentId"] as? String
            }()
            if let eAgentId = eventAgentId, eAgentId != myAgentId,
               !watchedAgentIds.contains(eAgentId) {
                return
            }
        }

        // Filter by subscription ID to avoid processing events from the global subscription.
        // Each event delivery includes a subscriptionId. Only process events matching OUR subscription.
        let eventSubscriptionId = dict["subscriptionId"] as? String
        if let mySubId = subscriptionId, let eventSubId = eventSubscriptionId, eventSubId != mySubId {
            return
        }

        let event: [String: Any]
        if let innerEvent = dict["event"] as? [String: Any] {
            event = innerEvent
        } else {
            event = dict
        }

        guard let eventType = event["type"] as? String,
              let data = event["data"] as? [String: Any] else { return }

        let eventAgentId = data["agentId"] as? String

        // Workspace-level events — handle regardless of which agent emitted them
        switch eventType {
        case "agent:deleted":
            // Our agent was deleted while its conversation is open — surface it
            // so the view falls back to the agent list. Handled before the
            // isLoading buffer so a deletion during the initial fetch is not lost.
            if let myAgentId = agentId, eventAgentId == myAgentId {
                agentNotFound = true
            }
            return
        case "agent:subscribed", "agent:unsubscribed", "agent:woken-by-subscription":
            if let agentId = self.agentId, let workspaceId = self.workspaceId {
                Task { await self.fetchSubscriptions(agentId: agentId, workspaceId: workspaceId) }
            }
            // If this event is also for our agent, continue processing below; otherwise return
            if eventAgentId != agentId { return }
        case "agent:status-changed", "agent:idle":
            // If this is a watched agent, immediately refresh just that agent
            if let eventAgentId {
                watchedAgentCoordinator.handleStatusChange(agentId: eventAgentId)
            }
            // Also re-fetch subscriptions for the parent agent (sub-agents completing may change groups)
            if let agentId = self.agentId, let workspaceId = self.workspaceId {
                Task { await self.fetchSubscriptions(agentId: agentId, workspaceId: workspaceId) }
            }
            if eventAgentId != agentId { return }
        case "agent:stream:activity":
            // Liveness ping ({ agentId, messageId }) throttled leading-edge by
            // the daemon (first chunk immediate, then ≤1/s per agent). The
            // payload carries live preview fields (lastAgentResponse, digest)
            // when the turn has produced them — apply those push-style to an
            // already-loaded watched agent instead of refetching via agent.get.
            if let eventAgentId {
                watchedAgentCoordinator.handleActivity(
                    agentId: eventAgentId,
                    lastAgentResponse: data["lastAgentResponse"] as? String,
                    digest: data["digest"] as? String)
            }
            guard eventAgentId == agentId else { return }
        case "agent:stream:end":
            // When a watched agent finishes streaming, always refresh (bypass debounce) for final state
            if let eventAgentId {
                watchedAgentCoordinator.handleStreamEnd(agentId: eventAgentId)
            }
            // Only continue processing if this is our agent
            guard eventAgentId == agentId else { return }
        default:
            // Agent-specific events — only handle for our agent
            guard eventAgentId == agentId else { return }
        }

        // When the chat.subscribe channel is live, block-level deltas own the transcript.
        // Drop firehose agent:stream:* mutations so they cannot create duplicate blocks
        // with client-generated ids that the terminal delta's removedIds cannot remove.
        // agent:stream:end stays as a benign safety net (its refetch is gated on live state).
        if liveTranscript.shouldSuppressFirehose(eventType: eventType) {
            return
        }

        // Buffer stream events while the initial conversation fetch is in progress
        if isLoading {
            streamEventBuffer.append((eventType: eventType, data: data))
            return
        }

        switch eventType {
        case "agent:stream:start":
            handleStreamStart(data)
        case "agent:stream:activity":
            handleStreamActivity()
        case "agent:stream:end":
            handleStreamEnd(data)
        case "agent:queue:updated":
            handleQueueUpdated(data)
        case "agent:queue:processing":
            handleQueueProcessing(data)
        case "agent:user-message:sent":
            handleUserMessageSent(data)
        case "agent:status-changed":
            let newStatus = data["status"] as? String
                ?? data["newStatus"] as? String
            let statusLower = newStatus?.lowercased() ?? ""
            if statusLower == "responding" || statusLower == "streaming" || statusLower == "processing" {
                isStreaming = true
            } else if statusLower == "idle" || statusLower == "completed" || statusLower == "failed" || statusLower == "error" {
                isStreaming = false
            }
            // Turn boundary — refresh the pending attention request (raised when
            // a turn ends, cleared when the agent next receives a message).
            if let agentId = self.agentId {
                Task { await self.fetchAgentStreamingState(agentId: agentId, raiseOnly: true) }
            }
        case "agent:idle":
            isStreaming = false
            // Re-fetch conversation to get final state (unless in live mode)
            if liveTranscript.shouldRefetchAfterLegacyStreamEnd,
               let agentId = self.agentId {
                Task { await self.fetchConversation(agentId: agentId) }
            }
            // Turn ended — refresh the pending attention request
            if let agentId = self.agentId {
                Task { await self.fetchAgentStreamingState(agentId: agentId, raiseOnly: true) }
            }
        case "agent:updated":
            // Session-mutation invalidation (PROTOCOL §6.5). The dismissal
            // marker persist carries it in the payload — apply push-style so
            // a dismissal from another client retires the wizard here too.
            if let dismissedId = data["dismissedQuestionsMessageId"] as? String {
                dismissedQuestionsMessageId = dismissedId
            }
            // Seen-marker persist (agent.markSeen, PROTOCOL §5.5) — converge
            // marker moves from other clients push-style.
            if let seenId = data["lastSeenMessageId"] as? String {
                lastSeenMessageId = seenId
            }
        default:
            break
        }
    }

    private func handleStreamStart(_ data: [String: Any]) {
        currentStreamId = data["streamId"] as? String
        isStreaming = true
    }

    /// `agent:stream:activity` is a content-free liveness ping — transcript
    /// content arrives via chat.subscribe / persisted messages. On the legacy
    /// (non-chatLive) fallback path this keeps the streaming flag raised
    /// between stream:start and stream:end.
    private func handleStreamActivity() {
        isStreaming = true
    }

    private func handleStreamEnd(_ data: [String: Any]) {
        isStreaming = false
        currentStreamId = nil
        streamingUpdateCount = 0

        // Mark the last streaming message as complete
        if let lastIndex = messages.indices.last,
           messages[lastIndex].isStreaming == true {
            messages[lastIndex].isStreaming = false
        }

        // Re-fetch to get the final server-side state (unless in live mode)
        if liveTranscript.shouldRefetchAfterLegacyStreamEnd,
           let agentId = agentId {
            Task { await fetchConversation(agentId: agentId) }
        }
    }

    private func handleQueueUpdated(_ data: [String: Any]) {
        // Try to use queue data from the event directly (avoids extra round-trip)
        if let queueItems = data["queue"] as? [[String: Any]] {
            if let jsonData = try? JSONSerialization.data(withJSONObject: queueItems),
               let parsed = try? JSONDecoder().decode([QueuedMessage].self, from: jsonData) {
                queuedMessages = parsed
                return
            }
        }
        // Fallback: re-fetch the queue
        if let agentId = agentId {
            Task { await fetchQueue(agentId: agentId) }
        }
    }

    private func handleQueueProcessing(_ data: [String: Any]) {
        // A queued message is being processed — remove it from local queue
        if let messageId = data["messageId"] as? String {
            queuedMessages.removeAll { $0.id == messageId }
        } else if let agentId = agentId {
            // Fallback: re-fetch queue
            Task { await fetchQueue(agentId: agentId) }
        }
    }

    private func handleUserMessageSent(_ data: [String: Any]) {
        guard let messageId = data["messageId"] as? String,
              let content = data["content"] as? String else { return }

        // Deduplicate: if we already have this message (optimistic add), skip
        if messages.contains(where: { $0.id == messageId }) {
            return
        }

        // Another client sent this message — append it to our conversation.
        // The block id mirrors the daemon's synthetic `{messageId}:0` (CS-0 D1)
        // so a later authoritative user-row delta upserts over this block
        // instead of appending a duplicate (same contract as sendMessage).
        let userMessage = ConversationMessage(
            id: messageId,
            role: .user,
            contentBlocks: [ContentBlock(id: "\(messageId):0", type: .text, text: content)]
        )
        withAnimation(.spring(
            response: Constants.Conversation.Sending.messageAppendSpringResponse,
            dampingFraction: Constants.Conversation.Sending.messageAppendSpringDamping
        )) {
            messages.append(userMessage)
        }
    }

    // MARK: - Send message

    /// `messageMetadata`, when present, rides the `agent.sendMessage` request
    /// verbatim (PROTOCOL §5.5) — the Agent Q&A wizard tags its answer with
    /// `{ type: "question_answers", answeredQuestionsMessageId }` so the
    /// daemon retires the question hold. Plain sends omit the key entirely.
    func sendMessage(agentId: String, content: String, workspaceId: String,
                     imageBlocks: [[String: Any]]? = nil,
                     fileBlocks: [[String: Any]]? = nil,
                     messageMetadata: [String: Any]? = nil) async throws {
        // Reuse messageId if retrying the same content after a failure
        let messageId: String
        if let failed = lastFailedSend, failed.content == content {
            messageId = failed.messageId
            // Remove stale optimistic message from previous attempt
            messages.removeAll { $0.id == failed.messageId }
        } else {
            messageId = UUID().uuidString
        }
        // Add user message locally for immediate UI feedback (use messageId for
        // dedup). The block id mirrors the daemon's synthetic `{messageId}:0`
        // (CS-0 D1) so the authoritative user-row delta (intentd#747) upserts
        // over this optimistic block instead of appending a duplicate.
        let userMessage = ConversationMessage(
            id: messageId,
            role: .user,
            contentBlocks: [ContentBlock(id: "\(messageId):0", type: .text, text: content)]
        )
        withAnimation(.spring(
            response: Constants.Conversation.Sending.messageAppendSpringResponse,
            dampingFraction: Constants.Conversation.Sending.messageAppendSpringDamping
        )) {
            messages.append(userMessage)
        }

        // Optimistically show thinking indicator immediately
        withAnimation(.easeOut(
            duration: Constants.Conversation.Sending.stateTransitionAnimationDuration
        )) {
            isStreaming = true
        }

        let queued: Bool
        do {
            queued = try await commands.sendMessage(
                agentId: agentId,
                content: content,
                workspaceId: workspaceId,
                messageId: messageId,
                imageBlocks: imageBlocks,
                fileBlocks: fileBlocks,
                messageMetadata: messageMetadata)
        } catch {
            // Track the failed send so retrying reuses the same messageId
            lastFailedSend = (messageId: messageId, content: content)
            throw error
        }

        // Send succeeded — clear any tracked failure
        lastFailedSend = nil

        // The daemon clears attention-request fields when the agent receives a
        // message — retire the indicator immediately rather than waiting for
        // the next agent.get refresh.
        attentionRequest = nil

        // If the message was queued, undo the optimistic streaming state
        if queued {
            isStreaming = false
            // Message was queued — remove the optimistic message from conversation
            // since it will appear in the queued messages panel instead
            withAnimation(.easeOut(
                duration: Constants.Conversation.Sending.stateTransitionAnimationDuration
            )) {
                messages.removeAll { $0.id == userMessage.id }
            }
        }
    }

    /// Roll back the optimistic UI state left behind by a failed `sendMessage`
    /// — the locally appended user message and the optimistic thinking
    /// indicator. `lastFailedSend` is kept so retrying the same content still
    /// reuses the messageId (server-side dedup). Used by the Agent Q&A wizard,
    /// where the optimistic message would otherwise permanently supersede the
    /// transcript-derived pending questions even though nothing reached the
    /// daemon.
    func rollbackFailedSend() {
        guard let failed = lastFailedSend else { return }
        withAnimation(.easeOut(
            duration: Constants.Conversation.Sending.stateTransitionAnimationDuration
        )) {
            messages.removeAll { $0.id == failed.messageId }
            isStreaming = false
        }
    }

    // MARK: - Dismiss questions

    /// Dismiss the pending Agent Q&A question set WITHOUT answering
    /// (`agent.dismissQuestions`, PROTOCOL §5.5). The daemon persists the
    /// `dismissedQuestionsMessageId` marker (survives restarts, so the set
    /// never re-surfaces), releases the question hold, and notifies the model
    /// with a system-origin `questions_dismissed` notice. The marker is raised
    /// optimistically BEFORE the RPC (FE parity: the mutation middleware
    /// stamps session metadata first) so the wizard unmounts immediately —
    /// closing the in-flight window where a Send or a second Dismiss could
    /// race the same question message (PR #86 review). A failed call rolls
    /// the marker back (the wizard re-pends) and rethrows.
    func dismissQuestions(agentId: String, messageId: String, workspaceId: String) async throws {
        try await commands.dismissQuestions(
            agentId: agentId, messageId: messageId, workspaceId: workspaceId)
    }

    // MARK: - Seen marker (agent.markSeen, PROTOCOL §5.5)

    /// Fire-and-forget `agent.markSeen`: advance the per-conversation seen
    /// marker to the newest persisted message. Never throws — the daemon call
    /// is idempotent and monotonic, so a failure just leaves the marker behind
    /// and the next trigger retries (the dedupe record is rolled back).
    func markSeen(agentId: String, workspaceId: String) async {
        await commands.markSeen(
            agentId: agentId, workspaceId: workspaceId, messages: messages)
    }

    func queueMessage(agentId: String, content: String,
                      imageBlocks: [[String: Any]]? = nil,
                      fileBlocks: [[String: Any]]? = nil) async throws {
        try await commands.queueMessage(
            agentId: agentId, content: content,
            imageBlocks: imageBlocks, fileBlocks: fileBlocks)
    }

    func stopStreaming(agentId: String) async {
        do {
            try await commands.stop(agentId: agentId)
        } catch {
            AppLog.conversation.error("[ConversationStore] Failed to stop streaming: \(error)")
        }
    }

    func fetchQueue(agentId: String) async {
        do {
            try await commands.fetchQueue(agentId: agentId)
        } catch {
            AppLog.conversation.error("[ConversationStore] Failed to fetch queue: \(error)")
        }
    }

    func editQueuedMessage(agentId: String, messageId: String, content: String) async throws {
        try await commands.editQueuedMessage(
            agentId: agentId, messageId: messageId, content: content)
    }

    func sendQueuedMessageNow(agentId: String, messageId: String, workspaceId: String) async throws {
        try await commands.sendQueuedMessageNow(
            agentId: agentId, messageId: messageId, workspaceId: workspaceId)
    }

    func removeQueuedMessage(agentId: String, messageId: String) async throws {
        try await commands.removeQueuedMessage(agentId: agentId, messageId: messageId)
    }

    // MARK: - Models

    func getModels(agentId: String) async throws -> [[String: Any]] {
        try await commands.getModels(agentId: agentId)
    }

    func setModel(agentId: String, modelId: String, workspaceId: String) async throws {
        try await commands.setModel(
            agentId: agentId, modelId: modelId, workspaceId: workspaceId)
    }

    // MARK: - Agent subscriptions

    func fetchSubscriptions(agentId: String, workspaceId: String) async {
        await watchedAgentCoordinator.fetchSubscriptions(
            agentId: agentId, workspaceId: workspaceId)
    }

    func cancelSubscriptions(agentId: String, workspaceId: String) async {
        await watchedAgentCoordinator.cancelSubscriptions(
            agentId: agentId, workspaceId: workspaceId)
    }

    func stopWatchedAgents(agentIds: [String], parentAgentId: String, workspaceId: String) async {
        await watchedAgentCoordinator.stopAgents(
            agentIds: agentIds, parentAgentId: parentAgentId, workspaceId: workspaceId)
    }

    // MARK: - Cleanup

    func reset() {
        liveTranscript.reset()
        commands.reset()
        watchedAgentCoordinator.reset()
        agentId = nil
        workspaceId = nil
        subscriptionId = nil
        currentStreamId = nil
        isSubscribing = false
        streamEventBuffer.removeAll()
        lastFailedSend = nil
        attentionRequest = nil
        agentNotFound = false
    }
}