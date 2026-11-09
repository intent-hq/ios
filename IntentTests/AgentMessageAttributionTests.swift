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
            displayName: "Coordinator",
            headerName: "Coordinator"
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

    @Test func legacyAssistantSenderUsesCurrentName() {
        let attribution = AgentMessageAttribution.from([
            "type": AnyCodable("agent_message"),
            "fromAgentId": AnyCodable("assistant"),
            "fromAgentName": AnyCodable(" Chief of staff ")
        ])
        #expect(attribution?.rawName == "Assistant")
        #expect(attribution?.displayName == "Assistant")
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

// MARK: - Chief messages and the daemon sender header

struct AgentMessageSenderHeaderTests {
    private func attribution(name: String?, id: String = "agent-1") -> AgentMessageAttribution? {
        var metadata: [String: AnyCodable] = [
            "type": AnyCodable("agent_message"),
            "fromAgentId": AnyCodable(id)
        ]
        if let name { metadata["fromAgentName"] = AnyCodable(name) }
        return AgentMessageAttribution.from(metadata)
    }

    @Test func chiefMessageIsAttributedWithoutAgentNavigation() {
        let chief = AgentMessageAttribution.from([
            "type": AnyCodable("chief_message"),
            "fromAgentId": AnyCodable("agent-chief"),
            "fromAgentName": AnyCodable("Assistant"),
            "fromWorkspaceId": AnyCodable("chief")
        ])
        #expect(chief?.kind == .chief)
        #expect(chief?.fromAgentId == "agent-chief")
        #expect(chief?.rawName == "Assistant")
        #expect(attribution(name: "Coordinator")?.kind == .agent)
    }

    @Test func stripsTheExactHeaderBuiltFromMetadata() {
        let name = " Fix (v2) [beta] "
        let attribution = attribution(name: name)
        #expect(attribution?.headerName == name)
        let text = "[MESSAGE FROM AGENT \(name) (agent-1)]\n\nDo the thing\n\nThen report."
        #expect(AgentMessageAttribution.stripSenderHeader(text, attribution: attribution)
            == "Do the thing\n\nThen report.")
    }

    @Test func stripsTheNameAbsentHeaderShape() {
        let attribution = attribution(name: nil)
        #expect(attribution?.headerName == nil)
        #expect(AgentMessageAttribution.stripSenderHeader(
            "[MESSAGE FROM AGENT (agent-1)]\n\nBody",
            attribution: attribution
        ) == "Body")
    }

    @Test func consumesOnlyTheSeparatorLine() {
        let attribution = attribution(name: "Coordinator")
        #expect(AgentMessageAttribution.stripSenderHeader(
            "[MESSAGE FROM AGENT Coordinator (agent-1)]\n\n  indented body",
            attribution: attribution
        ) == "  indented body")
        #expect(AgentMessageAttribution.stripSenderHeader(
            "[MESSAGE FROM AGENT Coordinator (agent-1)]\nBody",
            attribution: attribution
        ) == "Body")
        #expect(AgentMessageAttribution.stripSenderHeader(
            "[MESSAGE FROM AGENT Coordinator (agent-1)]",
            attribution: attribution
        ).isEmpty)
    }

    @Test func fallsBackToTheDaemonShapeWithoutAttribution() {
        #expect(AgentMessageAttribution.stripSenderHeader(
            "[MESSAGE FROM AGENT Coordinator (agent-0a1b-2c3d)]\n\nBody",
            attribution: nil
        ) == "Body")
        #expect(AgentMessageAttribution.stripSenderHeader(
            "[MESSAGE FROM AGENT (agent-0a1b-2c3d)]\n\nBody",
            attribution: nil
        ) == "Body")
    }

    @Test func leavesLookalikeFirstLinesUnchanged() {
        let attribution = attribution(name: "Coordinator")
        for text in [
            "[MESSAGE FROM AGENT someone]\n\nBody",
            "[MESSAGE FROM AGENT Coordinator (agent-1)] trailing text",
            "Body\n[MESSAGE FROM AGENT Coordinator (agent-1)]",
            "[MESSAGE FROM AGENT Other (agent-zz)]\n\nBody"
        ] {
            #expect(AgentMessageAttribution.stripSenderHeader(text, attribution: attribution) == text)
        }
    }

    @Test func previewAndCopyTextOmitTheHeader() {
        let attribution = attribution(name: "Coordinator")
        let blocks = [
            ContentBlock(type: .text, text: "[MESSAGE FROM AGENT Coordinator (agent-1)]\n\nDo the thing\nnow"),
            ContentBlock(type: .text, text: "[MESSAGE FROM AGENT Coordinator (agent-1)]\n\nkept")
        ]
        #expect(MessageView.agentMessagePreview(from: blocks, agentMessage: attribution)
            == "Do the thing now [MESSAGE FROM AGENT Coordinator (agent-1)] kept")
        #expect(MessageView.userCopyText(from: blocks, agentMessage: attribution)
            == "Do the thing\nnow\n\n[MESSAGE FROM AGENT Coordinator (agent-1)]\n\nkept")
    }
}
