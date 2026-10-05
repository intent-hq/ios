import Foundation

extension ConversationLiveTranscript {
    func bind(agentId newAgentId: String, workspaceId: String?) {
        if agentId != newAgentId {
            bindingGeneration &+= 1
            resetOlderHistory()
            emptySnapshotRecoveryAttempts = 0
            // Snapshot waits and recovery timers belong to the binding they
            // were armed under; a new agent starts its own.
            cancelSnapshotRecovery()
            resumeSnapshotWaiters()
        }
        agentId = newAgentId
        if let workspaceId {
            self.workspaceId = workspaceId
        }
    }

    /// Returns `work` only while the transcript remains on its original agent.
    func whileBound<T: Sendable>(_ work: () async throws -> T) async rethrows -> T? {
        let generation = bindingGeneration
        let value = try await work()
        guard generation == bindingGeneration else { return nil }
        return value
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
}
