@testable import Intent
import Testing

// MARK: - Agent-to-agent message attribution

struct AgentMessageAttributionTests {
    @Test func extractsFromValidMetadata() {
        let attribution = AgentMessageAttribution.from([
            "type": AnyCodable("agent_message"),
            "fromAgentId": AnyCodable("agent-1"),
            "fromAgentName": AnyCodable("Coordinator")
        ])
        #expect(attribution == AgentMessageAttribution(
            fromAgentId: "agent-1",
            rawName: "Coordinator",
            displayName: "Coordinator"
        ))
    }

    @Test func nilWhenMetadataAbsentOrWrongType() {
        let message = ConversationMessage(
            id: "m0",
            role: .user,
            contentBlocks: [ContentBlock(type: .text, text: "x")],
            timestamp: "2025-01-01T00:00:00Z"
        )
        #expect(!message.hasReportedMetadata)
        #expect(message.agentMessageAttribution == nil)
        #expect(AgentMessageAttribution.from([:]) == nil)
        #expect(AgentMessageAttribution.from([
            "type": AnyCodable("hook_wake"),
            "fromAgentId": AnyCodable("agent-1")
        ]) == nil)
    }

    @Test func nilWhenFromAgentIdMissingBlankOrNonString() {
        #expect(AgentMessageAttribution.from(["type": AnyCodable("agent_message")]) == nil)
        #expect(AgentMessageAttribution.from([
            "type": AnyCodable("agent_message"),
            "fromAgentId": AnyCodable("   ")
        ]) == nil)
        // Non-string ids are rejected like missing ones (FE parity:
        // `typeof md.fromAgentId === 'string'`).
        #expect(AgentMessageAttribution.from([
            "type": AnyCodable("agent_message"),
            "fromAgentId": AnyCodable(42)
        ]) == nil)
    }

    @Test func fallsBackToAgentNameWhenAbsentOrBlank() {
        let absent = AgentMessageAttribution.from([
            "type": AnyCodable("agent_message"),
            "fromAgentId": AnyCodable("agent-1")
        ])
        #expect(absent?.displayName == "Agent")
        #expect(absent?.rawName == "Agent")
        let blank = AgentMessageAttribution.from([
            "type": AnyCodable("agent_message"),
            "fromAgentId": AnyCodable("agent-1"),
            "fromAgentName": AnyCodable("   ")
        ])
        #expect(blank?.displayName == "Agent")
        #expect(blank?.rawName == "Agent")
    }

    @Test func trimsAndTruncatesLongNames() {
        let attribution = AgentMessageAttribution.from([
            "type": AnyCodable("agent_message"),
            "fromAgentId": AnyCodable(" agent-1 "),
            "fromAgentName": AnyCodable(" A very long agent name that keeps going ")
        ])
        #expect(attribution?.fromAgentId == "agent-1")
        #expect(attribution?.displayName == "A very long agent n…")
        #expect(attribution?.displayName.count == 20)
        // The untruncated (trimmed) name survives for surfaces that need it,
        // e.g. titling the pushed sender conversation.
        #expect(attribution?.rawName == "A very long agent name that keeps going")
    }

    @Test func messageAttributionChecksRowThenBlockMetadata() {
        let meta: [String: AnyCodable] = [
            "type": AnyCodable("agent_message"),
            "fromAgentId": AnyCodable("agent-1")
        ]
        let fromRow = ConversationMessage(
            id: "m1",
            role: .user,
            contentBlocks: [ContentBlock(type: .text, text: "x")],
            timestamp: "2025-01-01T00:00:00Z",
            metadata: meta
        )
        #expect(fromRow.agentMessageAttribution?.fromAgentId == "agent-1")

        let fromBlock = ConversationMessage(
            id: "m2",
            role: .user,
            contentBlocks: [ContentBlock(type: .text, text: "x", messageMetadata: meta)],
            timestamp: "2025-01-01T00:00:00Z"
        )
        #expect(fromBlock.agentMessageAttribution?.fromAgentId == "agent-1")

        let plain = ConversationMessage(
            id: "m3",
            role: .user,
            contentBlocks: [ContentBlock(type: .text, text: "x")],
            timestamp: "2025-01-01T00:00:00Z"
        )
        #expect(plain.agentMessageAttribution == nil)
    }
}
