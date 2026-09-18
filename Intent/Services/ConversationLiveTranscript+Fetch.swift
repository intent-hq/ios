import Foundation

extension ConversationLiveTranscript {
    func bind(agentId newAgentId: String, workspaceId: String?) {
        if agentId != newAgentId {
            bindingGeneration &+= 1
            emptySnapshotRecoveryAttempts = 0
        }
        agentId = newAgentId
        if let workspaceId {
            self.workspaceId = workspaceId
        }
    }

    /// Returns `work` only while the transcript remains on its original agent.
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
        let snapshotGenerationAtIssue = chatSnapshotGeneration

        var params: [String: Any] = [
            "agentId": agentId,
            "projection": "slim"
        ]
        if let workspaceId = workspaceId ?? self.workspaceId {
            params["workspaceId"] = workspaceId
        }
        // Carry errors as values so failures from a prior binding are dropped.
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
                    "[ConversationStore] Dropped stale fetch failure for a previous binding: \(error)"
                )
            }
        }

        applyFetchOutcome(outcome, snapshotGenerationAtIssue: snapshotGenerationAtIssue)
        finishInitialLoad(ifNeeded: isInitialLoad, outcomeWasCurrent: outcome != nil)
    }

    private func applyFetchOutcome(
        _ outcome: Result<ConversationPage?, Error>?,
        snapshotGenerationAtIssue: Int
    ) {
        switch outcome {
        case .success(let page?):
            // An empty fetched page may complete an already-empty load, but
            // cannot prune rows supplied by either live pushes or another fetch.
            if page.messages.isEmpty, !messages.isEmpty {
                AppLog.conversation.debug(
                    "[ConversationStore] Dropped empty fetch reply over populated transcript"
                )
                return
            }
            // Preserve populated live state after any later live generation.
            // An empty transcript deliberately admits a non-empty page despite
            // a mismatch: without a shared revision, this is the recovery path
            // for a delayed empty snapshot followed by a populated fetch.
            if snapshotGenerationAtIssue != chatSnapshotGeneration, !messages.isEmpty {
                AppLog.conversation.debug(
                    "[ConversationStore] Dropped fetch reply after later live chat changes preserved populated state"
                )
                return
            }
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
    }

    private func finishInitialLoad(ifNeeded isInitialLoad: Bool, outcomeWasCurrent: Bool) {
        guard isInitialLoad else { return }
        inFlightInitialLoads -= 1
        // A stale initial fetch must not finish the new binding's own load.
        if outcomeWasCurrent || inFlightInitialLoads == 0 {
            onInitialLoadCompleted?()
            isLoading = false
        }
    }

    private func reportFetchError(_ error: Error) {
        onFetchError?(error)
        AppLog.conversation.error(
            "[ConversationStore] Failed to fetch conversation: \(error)"
        )
    }

    nonisolated private struct ConversationPage: Sendable {
        let messages: [ConversationMessage]
        let truncated: Bool
        let totalMessages: Int?
    }

    @concurrent
    nonisolated private static func decodeConversationPage(
        _ result: InboundJSONValue
    ) async -> ConversationPage? {
        guard let response = result.value as? [String: Any],
              let items = response["messages"] as? [[String: Any]] else { return nil }
        return ConversationPage(
            messages: ConversationMessage.parseMessages(items),
            truncated: response["truncated"] as? Bool ?? false,
            totalMessages: response["totalMessages"] as? Int
        )
    }

    /// `blockId` is the requested block's id: a hydrated body served without
    /// its own `id` keeps the identity of the row it replaces.
    @concurrent
    nonisolated static func decodeMessageBlock(
        _ result: InboundJSONValue,
        blockId: String
    ) async -> ContentBlock? {
        guard let response = result.value as? [String: Any],
              let blockDictionary = response["block"] as? [String: Any] else { return nil }
        return ContentBlock.decode(blockDictionary, fallbackIdentity: .fixed(blockId))
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
        messages.sort { left, right in
            (order[left.id] ?? Int.max) < (order[right.id] ?? Int.max)
        }
    }
}
