import Foundation
import Testing
@testable import Intent

@Suite("AgentSession parsing and display")
struct AgentSessionTests {

    // MARK: - parseAgent

    @Test func parseCompleteAgent() {
        let dict: [String: Any] = [
            "id": "agent-1",
            "name": "Fix Bug",
            "status": "responding",
            "isStreaming": true,
            "isProcessing": false,
            "isResponding": true,
            "isWaitingForOtherAgents": true,
            "waitingForAgentIds": ["agent-9"],
            "createdAt": "2026-01-01T00:00:00Z",
            "updatedAt": "2026-01-02T00:00:00Z",
            "lastActivity": "2026-01-02T12:00:00Z",
            "lastAgentResponse": "Done",
            "lastUserMessage": "Fix it",
            "digest": "Fixed the bug",
            "metadata": [
                "isBackground": true,
                "specialist": "implementor",
                "createdByAgentId": "agent-0"
            ] as [String: Any]
        ]
        let agent = AgentSession.parseAgent(dict)
        #expect(agent != nil)
        #expect(agent?.id == "agent-1")
        #expect(agent?.name == "Fix Bug")
        #expect(agent?.status == "responding")
        #expect(agent?.isBackground == true)
        #expect(agent?.isStreaming == true)
        #expect(agent?.isProcessing == false)
        #expect(agent?.isResponding == true)
        #expect(agent?.isWaitingForOtherAgents == true)
        #expect(agent?.waitingForAgentIds == ["agent-9"])
        #expect(agent?.createdAt == "2026-01-01T00:00:00Z")
        #expect(agent?.updatedAt == "2026-01-02T00:00:00Z")
        #expect(agent?.lastActivity == "2026-01-02T12:00:00Z")
        #expect(agent?.lastAgentResponse == "Done")
        #expect(agent?.lastUserMessage == "Fix it")
        #expect(agent?.digest == "Fixed the bug")
        #expect(agent?.specialist == "implementor")
        #expect(agent?.createdByAgentId == "agent-0")
    }

    @Test func parseMinimalAgent() {
        let dict: [String: Any] = ["id": "agent-2", "name": "Test"]
        let agent = AgentSession.parseAgent(dict)
        #expect(agent != nil)
        #expect(agent?.id == "agent-2")
        #expect(agent?.name == "Test")
        #expect(agent?.status == "Idle")
        #expect(agent?.isBackground == false)
        #expect(agent?.isStreaming == false)
        #expect(agent?.isProcessing == false)
        #expect(agent?.isResponding == false)
        #expect(agent?.isWaitingForOtherAgents == false)
        #expect(agent?.waitingForAgentIds == [])
        #expect(agent?.createdAt == nil)
        #expect(agent?.specialist == nil)
        #expect(agent?.createdByAgentId == nil)
    }

    @Test func parseMissingIdReturnsNil() {
        let dict: [String: Any] = ["name": "No ID"]
        #expect(AgentSession.parseAgent(dict) == nil)
    }

    @Test func parseMissingNameReturnsNil() {
        let dict: [String: Any] = ["id": "agent-3"]
        #expect(AgentSession.parseAgent(dict) == nil)
    }

    @Test func parseEmptyDictReturnsNil() {
        #expect(AgentSession.parseAgent([:]) == nil)
    }

    // MARK: - displayMessage

    @Test func displayMessagePrefersDigest() {
        let agent = makeAgent(digest: "digest text", lastAgentResponse: "response text")
        #expect(agent.displayMessage == "digest text")
    }

    @Test func displayMessageFallsToLastResponse() {
        let agent = makeAgent(digest: nil, lastAgentResponse: "response text")
        #expect(agent.displayMessage == "response text")
    }

    @Test func displayMessageNilWhenBothNil() {
        let agent = makeAgent(digest: nil, lastAgentResponse: nil)
        #expect(agent.displayMessage == nil)
    }

    @Test func displayMessageStripsGroupTags() {
        let raw = "<group:Setup>Hello</group:Setup>"
        let agent = makeAgent(lastAgentResponse: raw)
        #expect(agent.displayMessage == "Hello")
    }

    @Test func displayMessageStripsClosingGroupWithoutName() {
        let raw = "<group:Work>Content</group>"
        let agent = makeAgent(lastAgentResponse: raw)
        #expect(agent.displayMessage == "Content")
    }

    @Test func displayMessageStripsAgentDigestBlock() {
        let raw = "Before <agent_digest>summary</agent_digest> After"
        let agent = makeAgent(lastAgentResponse: raw)
        #expect(agent.displayMessage == "Before  After")
    }

    @Test func displayMessageStripsHTMLComments() {
        let raw = "Hello <!-- suggested-prompts\nRun tests\n--> World"
        let agent = makeAgent(lastAgentResponse: raw)
        #expect(agent.displayMessage == "Hello  World")
    }

    @Test func displayMessageReturnsNilWhenOnlyTags() {
        let raw = "<group:X></group:X>"
        let agent = makeAgent(lastAgentResponse: raw)
        #expect(agent.displayMessage == nil)
    }

    @Test func displayMessageMixedContent() {
        let raw = "<group:A>Real content</group>\n<!-- comment -->\n<agent_digest>d</agent_digest>"
        let agent = makeAgent(lastAgentResponse: raw)
        #expect(agent.displayMessage == "Real content")
    }

    // MARK: - isActive

    @Test func isActiveForRespondingStatus() {
        let agent = makeAgent(status: "responding")
        #expect(agent.isActive == true)
    }

    @Test func isActiveForActiveStatus() {
        let agent = makeAgent(status: "Active")
        #expect(agent.isActive == true)
    }

    @Test func isActiveForStreamingFlag() {
        let agent = makeAgent(status: "Idle", isStreaming: true)
        #expect(agent.isActive == true)
    }

    @Test func isActiveForProcessingFlag() {
        let agent = makeAgent(status: "Idle", isProcessing: true)
        #expect(agent.isActive == true)
    }

    @Test func isActiveForRespondingFlag() {
        let agent = makeAgent(status: "Idle", isResponding: true)
        #expect(agent.isActive == true)
    }

    @Test func notActiveForIdleStatus() {
        let agent = makeAgent(status: "Idle")
        #expect(agent.isActive == false)
    }

    @Test func notActiveForUnknownStatus() {
        let agent = makeAgent(status: "completed")
        #expect(agent.isActive == false)
    }

    // MARK: - Helpers

    private func makeAgent(
        status: String = "Idle",
        isStreaming: Bool = false,
        isProcessing: Bool = false,
        isResponding: Bool = false,
        digest: String? = nil,
        lastAgentResponse: String? = nil
    ) -> AgentSession {
        AgentSession(
            id: "test", name: "Test", status: status,
            isBackground: false, isStreaming: isStreaming,
            isProcessing: isProcessing, isResponding: isResponding,
            isWaitingForOtherAgents: false, waitingForAgentIds: [],
            createdAt: nil, updatedAt: nil, lastActivity: nil,
            lastAgentResponse: lastAgentResponse, lastUserMessage: nil,
            digest: digest, specialist: nil, createdByAgentId: nil
        )
    }
}

