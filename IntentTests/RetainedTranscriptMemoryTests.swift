import Foundation
@testable import Intent
import Testing

/// Read-only mode keeps the last `ConversationStorePool.retainedConversationLimit`
/// conversations in memory. This measures what that costs with long transcripts:
/// the store-owned data model only (rows, blocks, search state), since the screens
/// that render them are gone once a conversation is no longer open.
@Suite(.serialized)
@MainActor
struct RetainedTranscriptMemoryTests {
    private static let messagesPerConversation = 2000
    private static let textLength = 1200
    private static let bytesPerMegabyte = 1 << 20
    /// Generous ceiling for 10 retained 2,000-message transcripts; tightens if the data model slims down.
    private static let retainedCeilingMegabytes = 400

    private static func footprintBytes() -> Int {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { raw in
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), raw, &count)
            }
        }
        return status == KERN_SUCCESS ? Int(info.phys_footprint) : 0
    }

    private static func rows(conversation: Int) -> [[String: Any]] {
        let body = String(repeating: "Retained transcript text for the read-only memory check. ", count: textLength / 58 + 1)
        return (0..<messagesPerConversation).map { index in
            [
                "id": "c\(conversation)-m\(index)",
                "role": index.isMultiple(of: 2) ? "user" : "assistant",
                "timestamp": "2026-01-01T00:00:00Z",
                "contentBlocks": [["type": "text", "id": "c\(conversation)-m\(index):0", "text": "\(index): \(body)"]]
            ] as [String: Any]
        }
    }

    @Test func tenLongRetainedTranscriptsStayWithinTheMemoryCeiling() async {
        let fake = FakeConnectionManager()
        let pool = ConversationStorePool(connection: fake, details: AgentDetailStore(connection: fake))
        let before = Self.footprintBytes()
        var loaded = 0
        for conversation in 0..<ConversationStorePool.retainedConversationLimit {
            fake.stubChatSnapshot(subscriptionId: "sub-\(conversation)", messages: Self.rows(conversation: conversation))
            let store = pool.store(agentId: "agent-\(conversation)")
            await store.subscribeLiveChat(agentId: "agent-\(conversation)", workspaceId: "w")
            loaded += store.messages.count
        }
        let afterBytes = Self.footprintBytes()
        let retainedMegabytes = (afterBytes - before) / Self.bytesPerMegabyte
        print("[read-only] retained \(ConversationStorePool.retainedConversationLimit) conversations x \(Self.messagesPerConversation) messages (\(loaded) rows loaded): footprint +\(retainedMegabytes) MB")
        #expect(loaded > 0, "The transcripts must actually load into the stores")
        #expect(retainedMegabytes < Self.retainedCeilingMegabytes)
        withExtendedLifetime(pool) {}
    }
}
