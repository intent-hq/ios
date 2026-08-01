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
            "lastMessageRole": "assistant",
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
        #expect(agent?.lastMessageRole == "assistant")
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
        #expect(agent?.lastMessageRole == nil)
        #expect(agent?.specialist == nil)
        #expect(agent?.createdByAgentId == nil)
        #expect(agent?.attentionRequestKind == nil)
        #expect(agent?.attentionRequestReason == nil)
        #expect(agent?.attentionRequestTimestamp == nil)
        #expect(agent?.hasPendingAttentionRequest == false)
    }

    // MARK: - attention-request fields (PROTOCOL §5.5)

    @Test func parseAttentionFieldsTopLevel() {
        // agent.getSession serves the fields top-level on the session.
        let dict: [String: Any] = [
            "id": "agent-4",
            "name": "Blocked Agent",
            "attentionRequestKind": "blocker",
            "attentionRequestReason": "sandbox is broken",
            "attentionRequestTimestamp": "2026-07-30T10:00:00Z"
        ]
        let agent = AgentSession.parseAgent(dict)
        #expect(agent?.attentionRequestKind == "blocker")
        #expect(agent?.attentionRequestReason == "sandbox is broken")
        #expect(agent?.attentionRequestTimestamp == "2026-07-30T10:00:00Z")
        #expect(agent?.hasPendingAttentionRequest == true)
    }

    @Test func parseAttentionFieldsFromMetadata() {
        // AgentLite (agent.list / agent.get) mirrors the fields under metadata.
        let dict: [String: Any] = [
            "id": "agent-5",
            "name": "Discussion Agent",
            "metadata": [
                "attentionRequestKind": "discussion",
                "attentionRequestReason": "need input on API shape",
                "attentionRequestTimestamp": "2026-07-30T11:00:00Z"
            ] as [String: Any]
        ]
        let agent = AgentSession.parseAgent(dict)
        #expect(agent?.attentionRequestKind == "discussion")
        #expect(agent?.attentionRequestReason == "need input on API shape")
        #expect(agent?.attentionRequestTimestamp == "2026-07-30T11:00:00Z")
        #expect(agent?.hasPendingAttentionRequest == true)
    }

    @Test func parseAttentionFieldsTopLevelWinsOverMetadata() {
        let dict: [String: Any] = [
            "id": "agent-6",
            "name": "Both",
            "attentionRequestKind": "blocker",
            "metadata": ["attentionRequestKind": "discussion"] as [String: Any]
        ]
        let agent = AgentSession.parseAgent(dict)
        #expect(agent?.attentionRequestKind == "blocker")
    }

    @Test func parseAttentionFieldsDoNotBlendSurfaces() {
        // The trio is resolved from the single surface carrying the kind; a
        // reason mirrored only on the other surface is not picked up.
        let dict: [String: Any] = [
            "id": "agent-6b",
            "name": "Mixed",
            "attentionRequestKind": "blocker",
            "metadata": ["attentionRequestReason": "metadata-only reason"] as [String: Any]
        ]
        let agent = AgentSession.parseAgent(dict)
        #expect(agent?.attentionRequestKind == "blocker")
        #expect(agent?.attentionRequestReason == nil)
    }

    // MARK: - parsePendingAttentionRequest (partial payloads)

    @Test func parsePendingAttentionRequestWithoutIdOrName() {
        // Raise/clear must not depend on the full session parse (id/name).
        let dict: [String: Any] = [
            "attentionRequestKind": "blocker",
            "attentionRequestReason": "sandbox is broken",
            "attentionRequestTimestamp": "2026-07-30T10:00:00Z"
        ]
        let pending = AgentSession.parsePendingAttentionRequest(dict)
        #expect(pending?.kind == .blocker)
        #expect(pending?.reason == "sandbox is broken")
        #expect(pending?.raisedAt == ISO8601DateFormatter().date(from: "2026-07-30T10:00:00Z"))
    }

    @Test func parsePendingAttentionRequestTimestampWithFractionalSeconds() {
        let dict: [String: Any] = [
            "attentionRequestKind": "discussion",
            "attentionRequestTimestamp": "2026-07-30T10:00:00.500Z"
        ]
        let pending = AgentSession.parsePendingAttentionRequest(dict)
        let expected = ISO8601DateFormatter().date(from: "2026-07-30T10:00:00Z")!
        #expect(pending?.raisedAt == expected.addingTimeInterval(0.5))
    }

    @Test func parsePendingAttentionRequestNilRaisedAtWhenTimestampAbsentOrInvalid() {
        let absent = AgentSession.parsePendingAttentionRequest([
            "attentionRequestKind": "blocker"
        ])
        #expect(absent != nil)
        #expect(absent?.raisedAt == nil)

        let invalid = AgentSession.parsePendingAttentionRequest([
            "attentionRequestKind": "blocker",
            "attentionRequestTimestamp": "not-a-date"
        ])
        #expect(invalid != nil)
        #expect(invalid?.raisedAt == nil)
    }

    @Test func parsePendingAttentionRequestFromMetadataSurface() {
        let dict: [String: Any] = [
            "metadata": ["attentionRequestKind": "discussion"] as [String: Any]
        ]
        #expect(AgentSession.parsePendingAttentionRequest(dict)?.kind == .discussion)
    }

    @Test func parsePendingAttentionRequestNilWhenAbsent() {
        #expect(AgentSession.parsePendingAttentionRequest(["id": "agent-6c"]) == nil)
    }

    // MARK: - pendingAttentionRequest derivation

    @Test func pendingAttentionRequestNilWhenNoKind() {
        let dict: [String: Any] = ["id": "agent-8", "name": "Idle"]
        let agent = AgentSession.parseAgent(dict)
        #expect(agent?.pendingAttentionRequest == nil)
    }

    @Test func pendingAttentionRequestDiscussion() {
        let dict: [String: Any] = [
            "id": "agent-9",
            "name": "Discuss",
            "attentionRequestKind": "discussion",
            "attentionRequestReason": "need input on API shape"
        ]
        let pending = AgentSession.parseAgent(dict)?.pendingAttentionRequest
        #expect(pending?.kind == .discussion)
        #expect(pending?.reason == "need input on API shape")
        #expect(pending?.kind.label == "Discussion requested")
    }

    @Test func pendingAttentionRequestBlocker() {
        let dict: [String: Any] = [
            "id": "agent-10",
            "name": "Blocked",
            "attentionRequestKind": "blocker",
            "attentionRequestReason": "sandbox is broken",
            "attentionRequestTimestamp": "2026-07-30T10:00:00Z"
        ]
        let pending = AgentSession.parseAgent(dict)?.pendingAttentionRequest
        #expect(pending?.kind == .blocker)
        #expect(pending?.reason == "sandbox is broken")
        #expect(pending?.kind.label == "Blocker reported")
        #expect(pending?.raisedAt == ISO8601DateFormatter().date(from: "2026-07-30T10:00:00Z"))
    }

    @Test func pendingAttentionRequestUnknownKindFallsBackToDiscussion() {
        // Newer daemons may introduce kinds — still surface an indicator.
        let dict: [String: Any] = [
            "id": "agent-11",
            "name": "Future",
            "attentionRequestKind": "some-future-kind"
        ]
        let pending = AgentSession.parseAgent(dict)?.pendingAttentionRequest
        #expect(pending?.kind == .discussion)
    }

    @Test func pendingAttentionRequestReasonCollapsedToOneLiner() {
        let dict: [String: Any] = [
            "id": "agent-12",
            "name": "Multiline",
            "attentionRequestKind": "blocker",
            "attentionRequestReason": "line one\nline two\n\n  spaced   out  "
        ]
        let pending = AgentSession.parseAgent(dict)?.pendingAttentionRequest
        #expect(pending?.reason == "line one line two spaced out")
    }

    @Test func pendingAttentionRequestEmptyReasonBecomesNil() {
        let dict: [String: Any] = [
            "id": "agent-13",
            "name": "NoReason",
            "attentionRequestKind": "discussion",
            "attentionRequestReason": "   \n  "
        ]
        let pending = AgentSession.parseAgent(dict)?.pendingAttentionRequest
        #expect(pending != nil)
        #expect(pending?.reason == nil)
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

    // MARK: - displayMessage lastMessageRole precedence (PROTOCOL §5.5)

    @Test func displayMessagePrefersUserFirstLineWhenUserIsNewest() {
        let agent = makeAgent(
            digest: "old digest", lastAgentResponse: "old response",
            lastUserMessage: "Please rerun the tests", lastMessageRole: "user"
        )
        #expect(agent.displayMessage == "Please rerun the tests")
    }

    @Test func displayMessageUserNewestTakesFirstLineOnly() {
        let agent = makeAgent(
            lastUserMessage: "First line\nSecond line", lastMessageRole: "user"
        )
        #expect(agent.displayMessage == "First line")
    }

    @Test func displayMessageUserNewestSkipsBlankLeadingLines() {
        let agent = makeAgent(
            lastUserMessage: "\n  \nActual question", lastMessageRole: "user"
        )
        #expect(agent.displayMessage == "Actual question")
    }

    @Test func displayMessageAssistantNewestKeepsExistingBehavior() {
        let agent = makeAgent(
            digest: "digest text", lastAgentResponse: "response text",
            lastUserMessage: "user text", lastMessageRole: "assistant"
        )
        #expect(agent.displayMessage == "digest text")
    }

    @Test func displayMessageAbsentRoleKeepsExistingBehavior() {
        // Older daemons omit lastMessageRole — back-compat fallback.
        let agent = makeAgent(
            digest: "digest text", lastAgentResponse: "response text",
            lastUserMessage: "user text", lastMessageRole: nil
        )
        #expect(agent.displayMessage == "digest text")
    }

    @Test func displayMessageUserNewestWithBlankUserMessageFallsBack() {
        let agent = makeAgent(
            digest: "digest text", lastUserMessage: "   \n ",
            lastMessageRole: "user"
        )
        #expect(agent.displayMessage == "digest text")
    }

    @Test func displayMessageUserNewestWithNilUserMessageFallsBack() {
        let agent = makeAgent(
            lastAgentResponse: "response text", lastMessageRole: "user"
        )
        #expect(agent.displayMessage == "response text")
    }

    // MARK: - applyingPreview role flip

    @Test func applyingPreviewFlipsRoleToAssistant() {
        // Live agent text arriving mirrors the daemon's read-path overlay:
        // the agent-side preview resumes over the user's newest message.
        let agent = makeAgent(
            lastUserMessage: "Do the thing", lastMessageRole: "user"
        )
        #expect(agent.displayMessage == "Do the thing")
        let updated = agent.applyingPreview(
            lastAgentResponse: "On it — running now", digest: nil
        )
        #expect(updated.lastMessageRole == "assistant")
        #expect(updated.displayMessage == "On it — running now")
    }

    @Test func applyingPreviewWithNilFieldsKeepsRole() {
        let agent = makeAgent(
            lastUserMessage: "Do the thing", lastMessageRole: "user"
        )
        let updated = agent.applyingPreview(lastAgentResponse: nil, digest: nil)
        #expect(updated.lastMessageRole == "user")
        #expect(updated.displayMessage == "Do the thing")
    }

    @Test func applyingPreviewDigestOnlyKeepsRole() {
        // The daemon's read-path overlay flips the role only with the
        // response overlay; a digest-only payload keeps the persisted role.
        let agent = makeAgent(
            lastUserMessage: "Do the thing", lastMessageRole: "user"
        )
        let updated = agent.applyingPreview(
            lastAgentResponse: nil, digest: "Working on it"
        )
        #expect(updated.lastMessageRole == "user")
        #expect(updated.digest == "Working on it")
        #expect(updated.displayMessage == "Do the thing")
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
        lastAgentResponse: String? = nil,
        lastUserMessage: String? = nil,
        lastMessageRole: String? = nil
    ) -> AgentSession {
        AgentSession(
            id: "test", name: "Test", status: status,
            isBackground: false, isStreaming: isStreaming,
            isProcessing: isProcessing, isResponding: isResponding,
            isWaitingForOtherAgents: false, waitingForAgentIds: [],
            createdAt: nil, updatedAt: nil, lastActivity: nil,
            lastAgentResponse: lastAgentResponse,
            lastUserMessage: lastUserMessage,
            lastMessageRole: lastMessageRole,
            digest: digest, specialist: nil, createdByAgentId: nil,
            attentionRequestKind: nil, attentionRequestReason: nil,
            attentionRequestTimestamp: nil
        )
    }
}

