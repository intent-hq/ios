import Combine
import Foundation
import SwiftUI

@MainActor
class ConversationStore: ObservableObject {
    /// Only one store per agentId should process streaming events.
    /// The most recently subscribed store wins.
    private static var activeStores: [String: ObjectIdentifier] = [:]

    @Published var messages: [ConversationMessage] = []
    @Published var isStreaming = false
    @Published var isLoading = false
    @Published var queuedMessages: [QueuedMessage] = []
    @Published var streamingUpdateCount: Int = 0
    @Published var watchedAgentIds: [String] = []
    @Published var delegationGroupStatus: (completed: Int, total: Int)?
    @Published var isWaitingForAgents = false
    @Published var watchedAgents: [AgentSession] = []
    @Published var isTruncated: Bool = false
    @Published var totalMessageCount: Int = 0

    private var agentId: String?
    private var workspaceId: String?
    private var subscriptionId: String?
    private var connectionObserver: AnyCancellable?
    private var currentStreamId: String?
    private var isSubscribing = false
    private var eventHandlerId: UUID?
    /// Live-state tracking for chat.subscribe
    private var chatLive = false
    private var chatSubscriptionId: String?
    private var chatReconciler: DeltaReconciler<ConversationMessage>?
    private var resnapshotChatInProgress = false
    /// Tracks the last time we refreshed each watched agent (for debouncing stream:chunk refreshes)
    private var watchedAgentLastRefresh: [String: Date] = [:]
    /// Locally-extracted digests from watched agent stream chunks
    private var watchedAgentDigests: [String: String] = [:]
    /// Accumulated stream text per watched agent for digest extraction
    private var watchedAgentStreamBuffers: [String: String] = [:]
    /// Buffer for stream events that arrive while the initial conversation fetch is in progress.
    /// This prevents lost deltas when subscribing before fetching.
    private var streamEventBuffer: [(eventType: String, data: [String: Any])] = []

    /// Tracks the last failed send so retrying the same content reuses the messageId
    /// (preventing duplicate messages on the server).
    var lastFailedSend: (messageId: String, content: String)?

    init() {
        observeConnection()
    }

    /// Test-only helper to set reconciler for testing
    func setTestReconciler(_ reconciler: DeltaReconciler<ConversationMessage>) async {
        await MainActor.run {
            chatReconciler = reconciler
        }
    }

    // MARK: - Connection observation

    private func observeConnection() {
        connectionObserver = ConnectionManager.shared.$connectionState
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                if state == .connected {
                    Task { await self?.onReconnected() }
                }
            }
    }

    private func onReconnected() async {
        // Reset live-state tracking on new connection
        chatLive = false
        chatSubscriptionId = nil
        chatReconciler = nil
        resnapshotChatInProgress = false

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
    private func fetchAgentStreamingState(agentId: String) async {
        do {
            let result = try await ConnectionManager.shared.request(
                "agent.get",
                params: ["agentId": agentId]
            )
            if let dict = result as? [String: Any],
               let agentDict = dict["agent"] as? [String: Any] {
                let serverIsStreaming = agentDict["isStreaming"] as? Bool ?? false
                isStreaming = serverIsStreaming
            }
        } catch {
            print("[ConversationStore] Failed to fetch agent streaming state: \(error)")
        }
    }

    // MARK: - Fetch conversation

    func fetchConversation(agentId: String, workspaceId: String? = nil) async {
        self.agentId = agentId
        if let workspaceId = workspaceId {
            self.workspaceId = workspaceId
        }
        let isInitialLoad = messages.isEmpty
        if isInitialLoad {
            isLoading = true
        }
        do {
            var params: [String: Any] = ["agentId": agentId]
            if let wsId = workspaceId ?? self.workspaceId {
                params["workspaceId"] = wsId
            }
            let result = try await ConnectionManager.shared.request(
                "agent.getConversation",
                params: params
            )
            if let dict = result as? [String: Any],
               let items = dict["messages"] as? [[String: Any]] {
                let fetchedMessages = items.compactMap { ConversationMessage.parseMessage($0) }

                // Parse truncation metadata
                isTruncated = dict["truncated"] as? Bool ?? false
                totalMessageCount = dict["totalMessages"] as? Int ?? fetchedMessages.count

                if isInitialLoad {
                    messages = fetchedMessages
                } else {
                    // Merge: update existing messages in-place, append new ones, remove deleted ones.
                    // This avoids replacing the array wholesale which causes a UI flash.
                    let fetchedIds = Set(fetchedMessages.map { $0.id })

                    // Remove messages that no longer exist on server
                    messages.removeAll { !fetchedIds.contains($0.id) }

                    // Update existing messages and append new ones
                    for fetched in fetchedMessages {
                        if let existingIndex = messages.firstIndex(where: { $0.id == fetched.id }) {
                            messages[existingIndex] = fetched
                        } else {
                            messages.append(fetched)
                        }
                    }

                    // Ensure order matches server order
                    let orderMap = Dictionary(uniqueKeysWithValues: fetchedMessages.enumerated().map { ($1.id, $0) })
                    messages.sort { a, b in
                        let aOrder = orderMap[a.id] ?? Int.max
                        let bOrder = orderMap[b.id] ?? Int.max
                        return aOrder < bOrder
                    }
                }

                // Detect if the agent is already streaming from the fetched snapshot
                if let lastMsg = messages.last, lastMsg.role == .assistant, lastMsg.isStreaming == true {
                    isStreaming = true
                }
            }
        } catch {
            print("[ConversationStore] Failed to fetch conversation: \(error)")
        }
        if isInitialLoad {
            replayBufferedStreamEvents()
            isLoading = false
        }
    }

    // MARK: - Stream event buffer replay

    /// Replay buffered stream events after the initial fetch completes.
    /// Deduplicates chunk text that the fetched snapshot already contains.
    private func replayBufferedStreamEvents() {
        let buffer = streamEventBuffer
        streamEventBuffer.removeAll()
        guard !buffer.isEmpty else { return }

        // Replay user message events — these may not be in the fetch snapshot
        // if the message was created after the fetch started.
        // handleStreamMessage and handleUserMessageSent both deduplicate, so this is safe.
        for event in buffer where event.eventType == "agent:stream:message" {
            handleStreamMessage(event.data)
        }
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

        // Collect all buffered chunk text
        let bufferedChunkText = buffer
            .filter { $0.eventType == "agent:stream:chunk" }
            .compactMap { $0.data["content"] as? String }
            .joined()

        guard !bufferedChunkText.isEmpty else {
            // stream:start but no chunks yet — streaming state is already set
            return
        }

        // Mark the last assistant message as streaming so subsequent chunks append to it
        guard let lastIndex = messages.indices.last,
              messages[lastIndex].role == .assistant else {
            // No assistant message in snapshot — apply all chunks normally
            for event in buffer where event.eventType == "agent:stream:chunk" {
                handleStreamChunk(event.data)
            }
            return
        }

        messages[lastIndex].isStreaming = true
        isStreaming = true

        // Get the text already in the snapshot
        let snapshotText = (messages[lastIndex].contentBlocks ?? [])
            .filter { $0.type == .text }
            .compactMap { $0.resolvedText }
            .joined()

        // Find overlap: longest prefix of bufferedChunkText that matches end of snapshotText.
        // The snapshot may already contain some of the buffered chunk text since the fetch
        // happened after subscription started.
        var overlapLength = min(bufferedChunkText.count, snapshotText.count)
        while overlapLength > 0 {
            let snapshotSuffix = String(snapshotText.suffix(overlapLength))
            let bufferPrefix = String(bufferedChunkText.prefix(overlapLength))
            if snapshotSuffix == bufferPrefix {
                break
            }
            overlapLength -= 1
        }

        let newText = String(bufferedChunkText.dropFirst(overlapLength))
        if !newText.isEmpty {
            appendTextToLastBlock(at: lastIndex, text: newText)
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
            ConnectionManager.shared.removeEventHandler(id: handlerId)
        }

        // Register event handler
        eventHandlerId = ConnectionManager.shared.onEvent { [weak self] method, params in
            Task { @MainActor [weak self] in
                self?.handleStreamEvent(method, params: params)
            }
        }

        // Subscribe to agent stream events
        do {
            let result = try await ConnectionManager.shared.request(
                "events.subscribe",
                params: [
                    "eventTypes": [
                        "agent:stream:*", "agent:queue:*",
                        "agent:user-message:*",
                        "agent:subscribed", "agent:unsubscribed",
                        "agent:status-changed", "agent:idle",
                        "agent:woken-by-subscription",
                    ],
                    "workspaceId": workspaceId,
                    "replaceGroup": "streaming-\(agentId)",
                ]
            )
            if let dict = result as? [String: Any],
               let subId = dict["subscriptionId"] as? String {
                subscriptionId = subId
            }
            // Register as the active store for this agent
            ConversationStore.activeStores[agentId] = ObjectIdentifier(self)
            print("[ConversationStore] Subscribed to streaming events")
        } catch {
            print("[ConversationStore] Failed to subscribe: \(error)")
        }
    }

    // MARK: - Live chat subscription

    func subscribeLiveChat(agentId: String) async {
        // Initialize chat reconciler synchronously before await to eliminate race
        chatReconciler = DeltaReconciler<ConversationMessage>(
            getId: { dict in dict["id"] as? String },
            normalize: { dict in ConversationMessage.parseMessage(dict) }
        )

        do {
            let result = try await ConnectionManager.shared.request("chat.subscribe", params: [
                "agentId": agentId,
                "replaceGroup": "ios-chat-\(agentId)"
            ])
            if let dict = result as? [String: Any],
               let subId = dict["subscriptionId"] as? String {
                chatSubscriptionId = subId
                print("[ConversationStore] Subscribed to chat.subscribe: \(subId)")
            } else {
                // Response missing subscriptionId - clean up and fall back to legacy
                chatReconciler = nil
                chatSubscriptionId = nil
            }
        } catch {
            // Subscribe failed - clean up reconciler and fall back to legacy
            chatReconciler = nil
            chatSubscriptionId = nil
            print("[ConversationStore] chat.subscribe failed: \(error), falling back to legacy")
        }
    }

    private func handleChatSubscriptionPush(_ push: SubscriptionPush) {
        // Only process pushes if we have a reconciler ready
        guard let reconciler = chatReconciler else {
            return
        }

        // Gate on subscriptionId to avoid cross-contamination from other channels
        // Accept pushes if subscriptionId is nil (tiny window before response returns)
        if let subId = chatSubscriptionId, push.subscriptionId != subId {
            return
        }

        switch push.kind {
        case .snapshot:
            guard let rawItems = push.snapshot else { return }
            chatLive = true
            reconciler.applySnapshot(seq: push.seq, rawItems: rawItems)
            messages = reconciler.values()
            print("[ConversationStore] Applied chat snapshot with \(rawItems.count) messages, seq=\(push.seq)")

        case .delta:
            guard let delta = push.delta else { return }
            if reconciler.applyDelta(seq: push.seq, delta: delta) {
                messages = reconciler.values()
                print("[ConversationStore] Applied chat delta seq=\(push.seq), added=\(delta.added.count), updated=\(delta.updated.count), removed=\(delta.removedIds.count)")
            } else {
                // Gap detected — resnapshot (guard against storm)
                if !resnapshotChatInProgress {
                    resnapshotChatInProgress = true
                    print("[ConversationStore] Chat sequence gap detected at seq=\(push.seq), resubscribing...")
                    Task { await resnapshotChat() }
                }
            }
        }
    }

    private func resnapshotChat() async {
        resnapshotChatInProgress = true
        defer { resnapshotChatInProgress = false }

        chatLive = false
        chatReconciler?.reset()

        if let subId = chatSubscriptionId {
            do {
                let _ = try await ConnectionManager.shared.request("chat.unsubscribe", params: [
                    "subscriptionId": subId
                ])
            } catch {
                print("[ConversationStore] chat.unsubscribe failed: \(error)")
            }
        }

        chatSubscriptionId = nil

        if let agentId = agentId {
            await subscribeLiveChat(agentId: agentId)
            // Baseline refetch to bridge the gap during resnapshot
            await fetchConversation(agentId: agentId, workspaceId: workspaceId)
        }
    }

    /// Unsubscribe the previous server-side event subscription to prevent duplicate event delivery.
    private func unsubscribePrevious() async {
        // Clean up active store registry
        if let aid = agentId {
            if ConversationStore.activeStores[aid] == ObjectIdentifier(self) {
                ConversationStore.activeStores.removeValue(forKey: aid)
            }
        }
        guard let subId = subscriptionId else { return }
        subscriptionId = nil
        do {
            let _ = try await ConnectionManager.shared.request(
                "events.unsubscribe",
                params: ["subscriptionId": subId]
            )
            print("[ConversationStore] Unsubscribed previous subscription: \(subId)")
        } catch {
            print("[ConversationStore] Failed to unsubscribe: \(error)")
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
        // This is critical when multiple ConversationStore instances exist
        // (e.g., coverflow card + regular conversation view for the same agent).
        if let myAgentId = agentId {
            let eventAgentId: String? = {
                if let inner = dict["event"] as? [String: Any] {
                    let d = inner["data"] as? [String: Any] ?? inner
                    return d["agentId"] as? String ?? inner["agentId"] as? String
                }
                let d = dict["data"] as? [String: Any] ?? dict
                return d["agentId"] as? String ?? dict["agentId"] as? String
            }()
            if let eAgentId = eventAgentId, eAgentId != myAgentId {
                return
            }
        }

        // Filter by subscription ID to avoid processing events from the global subscription.
        // Each event delivery includes a subscriptionId. Only process events matching OUR subscription.
        let eventSubscriptionId = dict["subscriptionId"] as? String
        if let mySubId = subscriptionId, let eventSubId = eventSubscriptionId, eventSubId != mySubId {
            return
        }

        // Only the active store for this agent processes streaming events
        if let myAgentId = agentId,
           let activeId = ConversationStore.activeStores[myAgentId],
           activeId != ObjectIdentifier(self) {
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
        case "agent:subscribed", "agent:unsubscribed", "agent:woken-by-subscription":
            if let agentId = self.agentId, let workspaceId = self.workspaceId {
                Task { await self.fetchSubscriptions(agentId: agentId, workspaceId: workspaceId) }
            }
            // If this event is also for our agent, continue processing below; otherwise return
            if eventAgentId != agentId { return }
        case "agent:status-changed", "agent:idle":
            // If this is a watched agent, immediately refresh just that agent
            if let eventAgentId = eventAgentId, watchedAgentIds.contains(eventAgentId) {
                refreshWatchedAgent(agentId: eventAgentId)
            }
            // Also re-fetch subscriptions for the parent agent (sub-agents completing may change groups)
            if let agentId = self.agentId, let workspaceId = self.workspaceId {
                Task { await self.fetchSubscriptions(agentId: agentId, workspaceId: workspaceId) }
            }
            if eventAgentId != agentId { return }
        case "agent:stream:chunk":
            // Update watched agents periodically during streaming (debounced to ~3s)
            if let eventAgentId = eventAgentId, watchedAgentIds.contains(eventAgentId) {
                // Extract digest from chunk content
                if let content = data["content"] as? String {
                    watchedAgentStreamBuffers[eventAgentId, default: ""] += content
                    if let digest = Self.extractAgentDigest(from: watchedAgentStreamBuffers[eventAgentId]!) {
                        watchedAgentDigests[eventAgentId] = digest
                        // Remove digest tag from buffer
                        watchedAgentStreamBuffers[eventAgentId] = watchedAgentStreamBuffers[eventAgentId]!
                            .replacingOccurrences(
                                of: "<agent_digest>[\\s\\S]*?</agent_digest>",
                                with: "",
                                options: .regularExpression
                            )
                    }
                }
                let now = Date()
                let lastRefresh = watchedAgentLastRefresh[eventAgentId]
                if lastRefresh == nil || now.timeIntervalSince(lastRefresh!) >= 3.0 {
                    watchedAgentLastRefresh[eventAgentId] = now
                    refreshWatchedAgent(agentId: eventAgentId)
                }
            }
            guard eventAgentId == agentId else { return }
        case "agent:stream:end":
            // When a watched agent finishes streaming, always refresh (bypass debounce) for final state
            if let eventAgentId = eventAgentId, watchedAgentIds.contains(eventAgentId) {
                // Final digest extraction from remaining buffer
                if let buffer = watchedAgentStreamBuffers[eventAgentId],
                   let digest = Self.extractAgentDigest(from: buffer) {
                    watchedAgentDigests[eventAgentId] = digest
                }
                watchedAgentStreamBuffers.removeValue(forKey: eventAgentId)
                watchedAgentLastRefresh.removeValue(forKey: eventAgentId)
                refreshWatchedAgent(agentId: eventAgentId)
            }
            // Only continue processing if this is our agent
            guard eventAgentId == agentId else { return }
        case "agent:stream:tool_result", "agent:stream:tool_use":
            // Update watched agents after each tool call for granular progress
            if let eventAgentId = eventAgentId, watchedAgentIds.contains(eventAgentId) {
                refreshWatchedAgent(agentId: eventAgentId)
            }
            guard eventAgentId == agentId else { return }
        default:
            // Agent-specific events — only handle for our agent
            guard eventAgentId == agentId else { return }
        }

        // Buffer stream events while the initial conversation fetch is in progress
        if isLoading {
            streamEventBuffer.append((eventType: eventType, data: data))
            return
        }

        switch eventType {
        case "agent:stream:start":
            handleStreamStart(data)
        case "agent:stream:chunk":
            handleStreamChunk(data)
        case "agent:stream:end":
            handleStreamEnd(data)
        case "agent:stream:content-blocks":
            handleContentBlocks(data)
        case "agent:stream:tool_use":
            handleToolUse(data)
        case "agent:stream:tool_result":
            handleToolResult(data)
        case "agent:stream:message":
            handleStreamMessage(data)
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
        case "agent:idle":
            isStreaming = false
            // Re-fetch conversation to get final state (unless in live mode)
            if !chatLive, let agentId = self.agentId {
                Task { await self.fetchConversation(agentId: agentId) }
            }
        default:
            break
        }
    }

    private func handleStreamStart(_ data: [String: Any]) {
        currentStreamId = data["streamId"] as? String
        isStreaming = true
        // Keep placeholder visible — handleStreamChunk will replace it when real content arrives
    }

    private func handleStreamChunk(_ data: [String: Any]) {
        guard let content = data["content"] as? String else { return }

        // Append text to the last assistant message's last text block,
        // or create a new message/block if needed
        if let lastIndex = messages.indices.last,
           messages[lastIndex].role == .assistant,
           messages[lastIndex].isStreaming == true {
            // Append to existing streaming message
            appendTextToLastBlock(at: lastIndex, text: content)
        } else {
            // Create new streaming assistant message
            let msg = ConversationMessage(
                id: data["messageId"] as? String ?? UUID().uuidString,
                role: .assistant,
                contentBlocks: [ContentBlock(type: .text, text: content)],
                isStreaming: true
            )
            messages.append(msg)
        }
        streamingUpdateCount += 1
    }

    private func appendTextToLastBlock(at messageIndex: Int, text: String) {
        var blocks = messages[messageIndex].contentBlocks ?? []
        if let lastBlockIndex = blocks.indices.last, blocks[lastBlockIndex].type == .text {
            let existing = blocks[lastBlockIndex].resolvedText ?? ""
            blocks[lastBlockIndex] = ContentBlock(
                id: blocks[lastBlockIndex].id,
                type: .text,
                text: existing + text
            )
        } else {
            blocks.append(ContentBlock(type: .text, text: text))
        }
        messages[messageIndex].contentBlocks = blocks
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
        if !chatLive, let agentId = agentId {
            Task { await fetchConversation(agentId: agentId) }
        }
    }

    private func handleContentBlocks(_ data: [String: Any]) {
        guard let blocks = data["content"] as? [[String: Any]] else { return }
        guard let lastIndex = messages.indices.last,
              messages[lastIndex].role == .assistant else { return }

        var contentBlocks = messages[lastIndex].contentBlocks ?? []

        for blockDict in blocks {
            guard let typeStr = blockDict["type"] as? String else { continue }

            switch typeStr {
            case "tool_use":
                let block = ContentBlock(
                    type: .toolUse,
                    name: blockDict["name"] as? String ?? blockDict["toolName"] as? String,
                    input: (blockDict["input"] as? [String: Any])?.mapValues { AnyCodable($0) },
                    toolUseId: blockDict["id"] as? String ?? blockDict["toolUseId"] as? String
                )
                contentBlocks.append(block)

            case "tool_result":
                let block = ContentBlock(
                    type: .toolResult,
                    toolUseId: blockDict["tool_use_id"] as? String ?? blockDict["toolUseId"] as? String,
                    output: blockDict["content"].map { AnyCodable($0) },
                    isError: blockDict["is_error"] as? Bool ?? blockDict["isError"] as? Bool
                )
                contentBlocks.append(block)

            default:
                break
            }
        }

        messages[lastIndex].contentBlocks = contentBlocks
        streamingUpdateCount += 1
    }

    private func handleToolUse(_ data: [String: Any]) {
        guard let lastIndex = messages.indices.last,
              messages[lastIndex].role == .assistant else { return }

        let block = ContentBlock(
            type: .toolUse,
            name: data["name"] as? String ?? data["toolName"] as? String,
            input: (data["input"] as? [String: Any])?.mapValues { AnyCodable($0) },
            toolUseId: data["toolUseId"] as? String ?? data["id"] as? String
        )

        var blocks = messages[lastIndex].contentBlocks ?? []
        blocks.append(block)
        messages[lastIndex].contentBlocks = blocks
        streamingUpdateCount += 1
    }

    private func handleToolResult(_ data: [String: Any]) {
        guard let lastIndex = messages.indices.last,
              messages[lastIndex].role == .assistant else { return }

        let block = ContentBlock(
            type: .toolResult,
            toolUseId: data["toolUseId"] as? String,
            output: data["output"].map { AnyCodable($0) },
            isError: data["isError"] as? Bool ?? data["is_error"] as? Bool
        )

        var blocks = messages[lastIndex].contentBlocks ?? []
        blocks.append(block)
        messages[lastIndex].contentBlocks = blocks
        streamingUpdateCount += 1
    }

    private func handleStreamMessage(_ data: [String: Any]) {
        // A complete message arrived via streaming
        if let messageDict = data["message"] as? [String: Any],
           let msg = ConversationMessage.parseMessage(messageDict) {
            // Replace or append
            if let existingIndex = messages.firstIndex(where: { $0.id == msg.id }) {
                messages[existingIndex] = msg
            } else if msg.role == .user,
                      let firstTextBlock = msg.contentBlocks?.first(where: { $0.type == .text }),
                      let msgText = firstTextBlock.text,
                      messages.contains(where: { existing in
                          existing.role == .user &&
                          existing.contentBlocks?.first(where: { $0.type == .text })?.text == msgText
                      }) {
                // Deduplicate: a user message with the same text already exists
                // (optimistic add used a different ID than the server-generated one).
                // Skip appending to avoid duplicate user messages.
            } else {
                messages.append(msg)
            }
        }
        streamingUpdateCount += 1
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

        // Another client sent this message — append it to our conversation
        let userMessage = ConversationMessage(
            id: messageId,
            role: .user,
            contentBlocks: [ContentBlock(type: .text, text: content)]
        )
        withAnimation(.spring(response: 0.35, dampingFraction: 0.7)) {
            messages.append(userMessage)
        }
    }

    // MARK: - Send message

    func sendMessage(agentId: String, content: String, workspaceId: String,
                     imageBlocks: [[String: Any]]? = nil) async throws {
        // Reuse messageId if retrying the same content after a failure
        let messageId: String
        if let failed = lastFailedSend, failed.content == content {
            messageId = failed.messageId
            // Remove stale optimistic message from previous attempt
            messages.removeAll { $0.id == failed.messageId }
        } else {
            messageId = UUID().uuidString
        }
        var params: [String: Any] = [
            "agentId": agentId,
            "content": content,
            "workspaceId": workspaceId,
            "messageId": messageId,
        ]
        if let imageBlocks = imageBlocks {
            params["imageBlocks"] = imageBlocks
        }

        // Add user message locally for immediate UI feedback (use messageId for dedup)
        let userMessage = ConversationMessage(
            id: messageId,
            role: .user,
            contentBlocks: [ContentBlock(type: .text, text: content)]
        )
        withAnimation(.spring(response: 0.35, dampingFraction: 0.7)) {
            messages.append(userMessage)
        }

        // Optimistically show thinking indicator immediately
        withAnimation(.easeOut(duration: 0.2)) {
            isStreaming = true
        }

        let result: Any
        do {
            result = try await ConnectionManager.shared.request(
                "agent.sendMessage",
                params: params
            )
        } catch {
            // Track the failed send so retrying reuses the same messageId
            lastFailedSend = (messageId: messageId, content: content)
            throw error
        }

        // Send succeeded — clear any tracked failure
        lastFailedSend = nil

        // If the message was queued, undo the optimistic streaming state
        if let dict = result as? [String: Any],
           let queued = dict["queued"] as? Bool,
           queued {
            isStreaming = false
            // Message was queued — remove the optimistic message from conversation
            // since it will appear in the queued messages panel instead
            withAnimation(.easeOut(duration: 0.2)) {
                messages.removeAll { $0.id == userMessage.id }
            }
        }
    }

    // MARK: - Queue message

    func queueMessage(agentId: String, content: String,
                      imageBlocks: [[String: Any]]? = nil) async throws {
        var params: [String: Any] = [
            "agentId": agentId,
            "content": content,
        ]
        if let imageBlocks = imageBlocks {
            params["imageBlocks"] = imageBlocks
        }

        let result = try await ConnectionManager.shared.request(
            "agent.queueMessage",
            params: params
        )

        // Parse the queued message from response
        if let dict = result as? [String: Any],
           let qmDict = dict["queuedMessage"] as? [String: Any],
           let data = try? JSONSerialization.data(withJSONObject: qmDict),
           let qm = try? JSONDecoder().decode(QueuedMessage.self, from: data) {
            queuedMessages.append(qm)
        }
    }

    // MARK: - Stop streaming

    func stopStreaming(agentId: String) async {
        do {
            let _ = try await ConnectionManager.shared.request(
                "agent.stop",
                params: ["agentId": agentId]
            )
        } catch {
            print("[ConversationStore] Failed to stop streaming: \(error)")
        }
    }

    // MARK: - Fetch queue

    func fetchQueue(agentId: String) async {
        do {
            let result = try await ConnectionManager.shared.request(
                "agent.getQueue",
                params: ["agentId": agentId]
            )
            if let dict = result as? [String: Any],
               let items = dict["queue"] as? [[String: Any]] {
                let data = try JSONSerialization.data(withJSONObject: items)
                queuedMessages = (try? JSONDecoder().decode([QueuedMessage].self, from: data)) ?? []
            }
        } catch {
            print("[ConversationStore] Failed to fetch queue: \(error)")
        }
    }

    // MARK: - Edit queued message

    func editQueuedMessage(agentId: String, messageId: String, content: String) async throws {
        let _ = try await ConnectionManager.shared.request(
            "agent.editQueuedMessage",
            params: [
                "agentId": agentId,
                "messageId": messageId,
                "content": content,
            ]
        )
        if let idx = queuedMessages.firstIndex(where: { $0.id == messageId }) {
            queuedMessages[idx].content = content
        }
    }

    // MARK: - Send queued message now

    func sendQueuedMessageNow(agentId: String, messageId: String, workspaceId: String) async throws {
        guard let message = queuedMessages.first(where: { $0.id == messageId }) else { return }
        let content = message.content

        let _ = try await ConnectionManager.shared.request(
            "agent.forceMessage",
            params: [
                "agentId": agentId,
                "messageId": messageId,
                "content": content,
                "workspaceId": workspaceId,
            ]
        )
        queuedMessages.removeAll { $0.id == messageId }
    }

    // MARK: - Remove queued message

    func removeQueuedMessage(agentId: String, messageId: String) async throws {
        let _ = try await ConnectionManager.shared.request(
            "agent.removeQueuedMessage",
            params: [
                "agentId": agentId,
                "messageId": messageId,
            ]
        )
        queuedMessages.removeAll { $0.id == messageId }
    }

    // MARK: - Models

    func getModels(agentId: String) async throws -> [[String: Any]] {
        let result = try await ConnectionManager.shared.request(
            "agent.getModels",
            params: ["agentId": agentId]
        )
        if let dict = result as? [String: Any],
           let models = dict["models"] as? [[String: Any]] {
            return models
        }
        return []
    }

    func setModel(agentId: String, modelId: String, workspaceId: String) async throws {
        let _ = try await ConnectionManager.shared.request(
            "agent.setModel",
            params: [
                "agentId": agentId,
                "modelId": modelId,
                "workspaceId": workspaceId,
            ]
        )
    }

    // MARK: - Agent subscriptions

    func fetchSubscriptions(agentId: String, workspaceId: String) async {
        do {
            let result = try await ConnectionManager.shared.request(
                "agent.getSubscriptions",
                params: ["agentId": agentId, "workspaceId": workspaceId]
            )
            guard let dict = result as? [String: Any] else { return }

            let subs = dict["subscriptions"] as? [[String: Any]] ?? []
            let groups = dict["delegationGroups"] as? [[String: Any]] ?? []

            // Extract watched agent IDs from delegation groups and subscriptions
            var agentIds = Set<String>()
            for group in groups {
                if let expected = group["expectedAgentIds"] as? [String] {
                    agentIds.formUnion(expected)
                }
            }
            for sub in subs {
                if let filter = sub["filter"] as? [String: Any],
                   let actorIds = filter["actorIds"] as? [String] {
                    agentIds.formUnion(actorIds)
                }
            }

            watchedAgentIds = Array(agentIds)
            isWaitingForAgents = !agentIds.isEmpty
            await fetchWatchedAgentDetails()

            // Compute completion status from delegation groups
            if !groups.isEmpty {
                var completed = 0
                var total = 0
                for group in groups {
                    let expected = (group["expectedAgentIds"] as? [String])?.count ?? 0
                    let done = (group["completedAgentIds"] as? [String])?.count ?? 0
                    total += expected
                    completed += done
                }
                delegationGroupStatus = (completed: completed, total: total)
            } else {
                delegationGroupStatus = nil
            }
        } catch {
            print("[ConversationStore] Failed to fetch subscriptions: \(error)")
        }
    }

    func cancelSubscriptions(agentId: String, workspaceId: String) async {
        do {
            let _ = try await ConnectionManager.shared.request(
                "agent.cancelSubscriptions",
                params: ["agentId": agentId, "workspaceId": workspaceId]
            )
            watchedAgentIds = []
            isWaitingForAgents = false
            delegationGroupStatus = nil
            watchedAgents = []
            watchedAgentDigests.removeAll()
            watchedAgentStreamBuffers.removeAll()
        } catch {
            print("[ConversationStore] Failed to cancel subscriptions: \(error)")
        }
    }

    /// Immediately fetch and update a single watched agent's details
    private func refreshWatchedAgent(agentId: String) {
        Task { @MainActor in
            do {
                let result = try await ConnectionManager.shared.request(
                    "agent.get",
                    params: ["agentId": agentId]
                )
                guard let dict = result as? [String: Any],
                      let agentDict = dict["agent"] as? [String: Any],
                      var updated = AgentSession.parseAgent(agentDict) else { return }

                // Overlay locally-extracted digest if the server doesn't have one yet
                if updated.digest == nil, let localDigest = self.watchedAgentDigests[agentId] {
                    updated = updated.withDigest(localDigest)
                }

                if !updated.isActive {
                    self.watchedAgents.removeAll { $0.id == agentId }
                    self.watchedAgentIds.removeAll { $0 == agentId }
                    self.isWaitingForAgents = !self.watchedAgentIds.isEmpty
                    if self.watchedAgentIds.isEmpty {
                        self.delegationGroupStatus = nil
                    }
                } else {
                    // Update just this agent in the watchedAgents array
                    if let idx = self.watchedAgents.firstIndex(where: { $0.id == agentId }) {
                        self.watchedAgents[idx] = updated
                    } else {
                        // Agent wasn't in the list yet — add it
                        self.watchedAgents.append(updated)
                    }
                }
                print("[ConversationStore] Updated watched agent: \(updated.name): \(updated.displayMessage ?? "nil")")
            } catch {
                print("[ConversationStore] Failed to fetch watched agent \(agentId): \(error)")
            }
        }
    }

    private func fetchWatchedAgentDetails() async {
        guard let workspaceId = workspaceId else { return }
        guard !watchedAgentIds.isEmpty else {
            await MainActor.run { watchedAgents = [] }
            return
        }
        do {
            let result = try await ConnectionManager.shared.request(
                "agent.list",
                params: ["workspaceId": workspaceId]
            )
            guard let dict = result as? [String: Any],
                  let agentDicts = dict["agents"] as? [[String: Any]] else { return }
            let watchedSet = Set(watchedAgentIds)
            let agents = agentDicts.compactMap { AgentSession.parseAgent($0) }
                .filter { watchedSet.contains($0.id) }
            print("[ConversationStore] Fetched \(agents.count) watched agents: \(agents.map { "\($0.name): \($0.displayMessage ?? "nil")" })")
            await MainActor.run {
                self.watchedAgents = agents
            }
        } catch {
            print("[ConversationStore] Failed to fetch watched agent details: \(error)")
        }
    }

    func stopWatchedAgents(agentIds: [String], parentAgentId: String, workspaceId: String) async {
        // Cancel subscriptions first
        await cancelSubscriptions(agentId: parentAgentId, workspaceId: workspaceId)
        // Stop parent agent
        do {
            let _ = try await ConnectionManager.shared.request(
                "agent.stop", params: ["agentId": parentAgentId])
        } catch {
            print("[ConversationStore] Failed to stop parent agent: \(error)")
        }
        // Stop all watched agents
        for id in agentIds {
            do {
                let _ = try await ConnectionManager.shared.request(
                    "agent.stop", params: ["agentId": id])
            } catch {
                print("[ConversationStore] Failed to stop agent \(id): \(error)")
            }
        }
    }

    // MARK: - Cleanup

    func reset() {
        // Clean up active store registry
        if let aid = agentId {
            if ConversationStore.activeStores[aid] == ObjectIdentifier(self) {
                ConversationStore.activeStores.removeValue(forKey: aid)
            }
        }
        messages = []
        isStreaming = false
        isLoading = false
        queuedMessages = []
        streamingUpdateCount = 0
        watchedAgentIds = []
        delegationGroupStatus = nil
        isWaitingForAgents = false
        watchedAgents = []
        isTruncated = false
        totalMessageCount = 0
        agentId = nil
        workspaceId = nil
        subscriptionId = nil
        currentStreamId = nil
        isSubscribing = false
        streamEventBuffer.removeAll()
        lastFailedSend = nil
        watchedAgentLastRefresh.removeAll()
        watchedAgentDigests.removeAll()
        watchedAgentStreamBuffers.removeAll()
        chatLive = false
        chatSubscriptionId = nil
        chatReconciler = nil
        resnapshotChatInProgress = false
    }

    // MARK: - Digest Extraction

    /// Extract `<agent_digest>` content from text using regex, matching the Electron implementation.
    static func extractAgentDigest(from text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: "<agent_digest>([\\s\\S]*?)</agent_digest>"),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let captureRange = Range(match.range(at: 1), in: text) else {
            return nil
        }
        let digest = String(text[captureRange]).trimmingCharacters(in: .whitespacesAndNewlines)
        return digest.isEmpty ? nil : digest
    }
}

