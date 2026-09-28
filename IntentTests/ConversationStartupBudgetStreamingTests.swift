import Foundation
@testable import Intent
import Testing

extension ConversationStartupBudgetTests {
    @Test(arguments: [8, 16], [false, true])
    func matchedStreamRetainsFragmentsAuthorityAndCleanup(fragmentCount: Int, full: Bool) async throws {
        let trace = ConversationStreamingFixture(fragments: Array(repeating: String(repeating: "🦊", count: 32), count: fragmentCount))
        let connection = RPCRecordingConnection()
        let id = "budget-stream-\(fragmentCount)-\(full)"
        connection.responseMap["chat.subscribe"] = ["subscriptionId": id]
        connection.responseMap["chat.unsubscribe"] = [:]
        let store = ConversationStore(connectionManager: connection)
        defer { store.reset() }
        await store.subscribeLiveChat(agentId: ConversationStreamingFixture.agentId, workspaceId: "fixture-workspace")
        for original in trace.frames(encoding: full ? .full : .incremental) {
            var frame = try #require(canonicalToolResult(original) as? [String: Any])
            frame["subscriptionId"] = id
            try connection.deliverNotification(params: frame)
        }
        #expect(store.messages.first?.contentBlocks.first?.resolvedText == trace.finalText)
        #expect(store.messages.first?.contentBlocks.first { $0.type == .thinking }?.resolvedText == trace.finalThinking)
        #expect(store.messages.first?.contentBlocks.last?.resolvedToolUseId == "call-1")
        #expect(!store.isStreaming)
        #expect(connection.traffic().methodCounts == ["chat.subscribe": 1])
        let name = "stream-\(full ? "full" : "incremental")-\(fragmentCount)"
        try ConversationBudgetEvidence.emit(name + "-open", connection.traffic())
        store.reset()
        try await waitUntil("stream cleanup accounted") {
            connection.traffic().calls("chat.unsubscribe").count == 1 && connection.traffic().pendingCount == 0
        }
        try ConversationBudgetEvidence.emit(name + "-complete", connection.traffic())
    }

    @Test func matchedSequenceGapCountsReplacementSnapshotAndBothReleases() async throws {
        let fixture = ConversationBudgetFixture()
        defer { fixture.startup.stop() }
        let model = fixture.startup.makeViewModel()
        await model.load()
        let connection = fixture.connection
        let id = try #require(model.store.liveTranscript.chatSubscriptionId)
        try connection.deliverNotification(params: [
            "subscriptionId": id, "kind": "delta", "seq": 3,
            "delta": ["added": [], "updated": [], "removedIds": []]
        ])
        try await waitUntil("gap registration and snapshot settled") {
            connection.traffic().calls("chat.subscribe").count == 2
                && connection.traffic().notifications.count == 3 && connection.traffic().pendingCount == 0
        }
        #expect(model.store.liveTranscript.chatSubscriptionId != id)
        #expect(model.messages.count == 1)
        try ConversationBudgetEvidence.emit("gap-recovery-open", connection.traffic())
        try await fixture.stopAndWait()
        #expect(connection.traffic().calls("chat.unsubscribe").count == 2)
        try ConversationBudgetEvidence.emit("gap-recovery-complete", connection.traffic())
    }

    /// The earlier iOS-only streaming fixture intentionally accepts aliases.
    /// This matched trace uses the daemon's canonical tool_result field so the
    /// desktop strict decoder consumes the SAME content without dropping it.
    private func canonicalToolResult(_ value: Any) -> Any {
        if let rows = value as? [Any] { return rows.map(canonicalToolResult) }
        guard let dictionary = value as? [String: Any] else { return value }
        return Dictionary(uniqueKeysWithValues: dictionary.map { key, item in
            (key == "toolUseId" ? "tool_use_id" : key, canonicalToolResult(item))
        })
    }
}
