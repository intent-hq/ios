import Foundation

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
        let stateVersion = liveStateVersion
        let interval = ConversationTrace.begin("MessageBlockFetch", traceContext)
        defer { ConversationTrace.end("MessageBlockFetch", interval, traceContext) }

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
                traceEvent("MessageBlockResponse", "requestVersion=\(stateVersion)")
                return await Self.decodeMessageBlock(InboundJSONValue(value: result), blockId: blockId)
            }
            guard let decoded else { return }
            guard let block = decoded else {
                traceEvent("MessageBlockRejected", "reason=invalid_payload")
                AppLog.conversation.error(
                    "[ConversationStore] getMessageBlock returned no decodable block for \(key)"
                )
                return
            }
            // A text read begun before a live update cannot erase fragments
            // or an authoritative replacement that arrived while it waited.
            if block.type == .text || block.type == .thinking, stateVersion != liveStateVersion {
                traceEvent("MessageBlockRejected", "reason=live_state_changed requestVersion=\(stateVersion)")
                return
            }
            storeHydratedBlock(block, forKey: key)
            remergeHydratedBlocks()
            traceEvent("MessageBlockAccepted", "hydratedBlocks=\(hydratedBlocks.count)")
        } catch {
            traceEvent("MessageBlockFailed", "cancelled=\(Task.isCancelled)")
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

    /// Hydration may expand a partial text body, but a later live update or
    /// snapshot owns that text. Tool/image previews still keep their full body.
    func discardHydratedText(_ block: ContentBlock, messageId: String) {
        guard block.type == .text || block.type == .thinking else { return }
        let key = Self.hydratedBlockKey(messageId: messageId, blockId: block.id)
        guard hydratedBlocks.removeValue(forKey: key) != nil else { return }
        hydratedBlockOrder.removeAll { $0 == key }
    }

    func discardHydratedText(in messages: [ConversationMessage]) {
        for message in messages {
            for block in message.contentBlocks {
                discardHydratedText(block, messageId: message.id)
            }
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
}
