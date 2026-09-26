import Foundation
@testable import Intent
import Testing

extension AgentSessionTests {
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
        let raw = "Hello <!-- a note --> World"
        let agent = makeAgent(lastAgentResponse: raw)
        #expect(agent.displayMessage == "Hello  World")
    }

    @Test func displayMessageStripsWellFormedSuggestedPromptsBlock() {
        let raw = "Hello\n<!-- suggested-prompts\nRun tests\n-->\nWorld"
        let agent = makeAgent(lastAgentResponse: raw)
        #expect(agent.displayMessage == "Hello\nWorld")
    }

    @Test func displayMessageStripsInlineSuggestedPromptsComment() {
        // A one-liner comment mentioning suggested-prompts is not a block
        // opener (an opener ends its line), so it is stripped like any comment.
        let raw = "Hello <!-- suggested-prompts config note --> World"
        let agent = makeAgent(lastAgentResponse: raw)
        #expect(agent.displayMessage == "Hello  World")
    }

    @Test func displayMessageKeepsMalformedSuggestedPromptsBlock() {
        // An embedded `-->` (Mermaid edge, prose arrow) does not close a block,
        // so body text must survive intact.
        let raw = "Hello <!-- suggested-prompts\nA --> B"
        let agent = makeAgent(lastAgentResponse: raw)
        #expect(agent.displayMessage == raw)
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
            digest: "old digest",
            lastAgentResponse: "old response",
            lastUserMessage: "Please rerun the tests",
            lastMessageRole: "user"
        )
        #expect(agent.displayMessage == "Please rerun the tests")
    }

    @Test func displayMessageUserNewestTakesFirstLineOnly() {
        let agent = makeAgent(
            lastUserMessage: "First line\nSecond line",
            lastMessageRole: "user"
        )
        #expect(agent.displayMessage == "First line")
    }

    @Test func displayMessageUserNewestSkipsBlankLeadingLines() {
        let agent = makeAgent(
            lastUserMessage: "\n  \nActual question",
            lastMessageRole: "user"
        )
        #expect(agent.displayMessage == "Actual question")
    }

    @Test func displayMessageAssistantNewestKeepsExistingBehavior() {
        let agent = makeAgent(
            digest: "digest text",
            lastAgentResponse: "response text",
            lastUserMessage: "user text",
            lastMessageRole: "assistant"
        )
        #expect(agent.displayMessage == "digest text")
    }

    @Test func displayMessageAbsentRoleKeepsExistingBehavior() {
        // Older daemons omit lastMessageRole — back-compat fallback.
        let agent = makeAgent(
            digest: "digest text",
            lastAgentResponse: "response text",
            lastUserMessage: "user text",
            lastMessageRole: nil
        )
        #expect(agent.displayMessage == "digest text")
    }

    @Test func displayMessageUserNewestWithBlankUserMessageFallsBack() {
        let agent = makeAgent(
            digest: "digest text",
            lastUserMessage: "   \n ",
            lastMessageRole: "user"
        )
        #expect(agent.displayMessage == "digest text")
    }

    @Test func displayMessageUserNewestWithNilUserMessageFallsBack() {
        let agent = makeAgent(
            lastAgentResponse: "response text",
            lastMessageRole: "user"
        )
        #expect(agent.displayMessage == "response text")
    }

    // MARK: - applyingPreview role flip

    @Test func applyingPreviewFlipsRoleToAssistant() {
        // Live agent text arriving mirrors the daemon's read-path overlay:
        // the agent-side preview resumes over the user's newest message.
        let agent = makeAgent(
            lastUserMessage: "Do the thing",
            lastMessageRole: "user"
        )
        #expect(agent.displayMessage == "Do the thing")
        let updated = agent.applyingPreview(
            lastAgentResponse: "On it — running now",
            digest: nil
        )
        #expect(updated.lastMessageRole == "assistant")
        #expect(updated.displayMessage == "On it — running now")
    }

    @Test func applyingPreviewWithNilFieldsKeepsRole() {
        let agent = makeAgent(
            lastUserMessage: "Do the thing",
            lastMessageRole: "user"
        )
        let updated = agent.applyingPreview(lastAgentResponse: nil, digest: nil)
        #expect(updated.lastMessageRole == "user")
        #expect(updated.displayMessage == "Do the thing")
    }

    @Test func applyingPreviewDigestOnlyKeepsRole() {
        // The daemon's read-path overlay flips the role only with the
        // response overlay; a digest-only payload keeps the persisted role.
        let agent = makeAgent(
            lastUserMessage: "Do the thing",
            lastMessageRole: "user"
        )
        let updated = agent.applyingPreview(
            lastAgentResponse: nil,
            digest: "Working on it"
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

    // MARK: - pending-question markers (PROTOCOL §5.5)

    @Test func parsePendingQuestionMarkersFromMetadata() {
        let dict: [String: Any] = [
            "id": "agent-q",
            "name": "Asker",
            "metadata": [
                "pendingQuestionsMessageId": "msg-7",
                "dismissedQuestionsMessageId": "msg-3"
            ] as [String: Any]
        ]
        let agent = AgentSession.parseAgent(dict)
        #expect(agent?.pendingQuestionsMessageId == "msg-7")
        #expect(agent?.dismissedQuestionsMessageId == "msg-3")
        #expect(agent?.hasPendingQuestions == true)
    }
}

@MainActor
struct AgentRowPreviewTests {
    @Test(arguments: [
        ("[Review](https://example.com) and [spec](intent://local/note/spec)", "Review and spec"),
        ("<https://example.com>", "https://example.com"),
        ("[Email](mailto:hello@example.com)", "Email")
    ])
    func previewRemovesEveryLinkDestination(markdown: String, expected: String) {
        let preview = AgentRowView.previewText(markdown)
        #expect(String(preview.characters) == expected)
        #expect(preview.runs.allSatisfy { $0.link == nil })
    }

    @Test func previewKeepsInlineStylesAndWhitespace() throws {
        let preview = AgentRowView.previewText("[**Review** `code`](https://example.com)  with\n*care*")
        #expect(String(preview.characters) == "Review code  with\ncare")
        let bold = try #require(preview.range(of: "Review"))
        let code = try #require(preview.range(of: "code"))
        let italic = try #require(preview.range(of: "care"))
        #expect(preview[bold].inlinePresentationIntent?.contains(.stronglyEmphasized) == true)
        #expect(preview[code].inlinePresentationIntent?.contains(.code) == true)
        #expect(preview[italic].inlinePresentationIntent?.contains(.emphasized) == true)
        #expect(preview.runs.allSatisfy { $0.link == nil })
    }
}

extension AgentSessionTests {
    @Test func pendingQuestionMarkerAloneIsPending() {
        let dict: [String: Any] = [
            "id": "agent-q",
            "name": "Asker",
            "metadata": ["pendingQuestionsMessageId": "msg-7"] as [String: Any]
        ]
        let agent = AgentSession.parseAgent(dict)
        #expect(agent?.dismissedQuestionsMessageId == nil)
        #expect(agent?.hasPendingQuestions == true)
    }

    @Test func pendingMarkerEqualToDismissedIsNotPending() {
        let dict: [String: Any] = [
            "id": "agent-q",
            "name": "Asker",
            "metadata": [
                "pendingQuestionsMessageId": "msg-7",
                "dismissedQuestionsMessageId": "msg-7"
            ] as [String: Any]
        ]
        let agent = AgentSession.parseAgent(dict)
        #expect(agent?.hasPendingQuestions == false)
    }

    @Test func absentPendingMarkerIsNotPending() {
        let dict: [String: Any] = [
            "id": "agent-q",
            "name": "Asker",
            "metadata": ["dismissedQuestionsMessageId": "msg-3"] as [String: Any]
        ]
        let agent = AgentSession.parseAgent(dict)
        #expect(agent?.pendingQuestionsMessageId == nil)
        #expect(agent?.hasPendingQuestions == false)

        let minimal = AgentSession.parseAgent(["id": "agent-q", "name": "Asker"])
        #expect(minimal?.hasPendingQuestions == false)
    }

    @Test func emptyPendingMarkerIsAuthoritativeClear() {
        // The daemon writes "" at turn end when nothing is pending.
        let dict: [String: Any] = [
            "id": "agent-q",
            "name": "Asker",
            "metadata": ["pendingQuestionsMessageId": ""] as [String: Any]
        ]
        let agent = AgentSession.parseAgent(dict)
        #expect(agent?.pendingQuestionsMessageId?.isEmpty == true)
        #expect(agent?.hasPendingQuestions == false)
    }

    @Test func applyingPreviewKeepsQuestionMarkers() {
        let agent = makeAgent(
            pendingQuestionsMessageId: "msg-7",
            dismissedQuestionsMessageId: "msg-3"
        )
        let updated = agent.applyingPreview(lastAgentResponse: "text", digest: nil)
        #expect(updated.pendingQuestionsMessageId == "msg-7")
        #expect(updated.dismissedQuestionsMessageId == "msg-3")
        #expect(updated.hasPendingQuestions == true)
    }
}
