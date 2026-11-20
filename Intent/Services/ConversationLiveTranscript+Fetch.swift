import Foundation

extension ConversationLiveTranscript {
    var traceContext: String {
        "transcript=\(ObjectIdentifier(self)) workspace=\(workspaceId ?? "none") agent=\(agentId ?? "none") binding=\(bindingGeneration) registration=\(registrationGeneration) liveVersion=\(liveStateVersion)"
    }

    func traceEvent(_ name: StaticString, _ detail: @autoclosure () -> String) {
        guard ConversationTrace.enabled else { return }
        ConversationTrace.emit(name, "\(traceContext) \(detail())")
    }

    func bind(agentId newAgentId: String, workspaceId: String?) {
        if agentId != newAgentId {
            bindingGeneration &+= 1
            resetOlderHistory()
            emptySnapshotRecoveryAttempts = 0
            cancelSnapshotRecovery()
            resumeSnapshotWaiters()
        }
        agentId = newAgentId
        if let workspaceId {
            self.workspaceId = workspaceId
        }
        traceEvent("TranscriptBound", "messages=\(messages.count) seeded=\(chatSeeded) loading=\(isLoading)")
    }

    func whileBound<T: Sendable>(_ work: () async throws -> T) async rethrows -> T? {
        let generation = bindingGeneration
        let value = try await work()
        guard generation == bindingGeneration else {
            traceEvent("LoadRejected", "reason=binding_changed requestBinding=\(generation)")
            return nil
        }
        return value
    }

    @concurrent
    nonisolated static func decodeMessageBlock(
        _ result: InboundJSONValue,
        blockId: String
    ) async -> ContentBlock? {
        let interval = ConversationTrace.begin("MessageBlockDecode", "")
        var decoded = false
        defer { ConversationTrace.end("MessageBlockDecode", interval, "decoded=\(decoded)") }
        guard let response = result.value as? [String: Any],
              let blockDictionary = response["block"] as? [String: Any] else { return nil }
        let block = ContentBlock.decode(blockDictionary, fallbackIdentity: .fixed(blockId))
        decoded = block != nil
        return block
    }
}
