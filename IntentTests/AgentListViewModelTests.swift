@testable import Intent
import Testing

@Suite(.serialized)
struct AgentListViewModelTests {
    // MARK: - Helpers

    private func makeAgent(
        id: String = "agent-1",
        name: String = "Test Agent",
        status: String = "Idle",
        isBackground: Bool = false,
        isStreaming: Bool = false,
        isProcessing: Bool = false,
        isResponding: Bool = false,
        createdAt: String? = nil,
        updatedAt: String? = nil,
        lastActivity: String? = nil,
        lastAgentResponse: String? = nil,
        digest: String? = nil,
        specialist: String? = nil,
        createdByAgentId: String? = nil,
        attentionRequestKind: String? = nil,
        pendingQuestionsMessageId: String? = nil,
        dismissedQuestionsMessageId: String? = nil
    ) -> AgentSession {
        AgentSession(
            id: id,
            name: name,
            status: status,
            isBackground: isBackground,
            isStreaming: isStreaming,
            isProcessing: isProcessing,
            isResponding: isResponding,
            isWaitingForOtherAgents: false,
            waitingForAgentIds: [],
            createdAt: createdAt,
            updatedAt: updatedAt,
            lastActivity: lastActivity,
            lastAgentResponse: lastAgentResponse,
            lastUserMessage: nil,
            lastMessageRole: nil,
            digest: digest,
            specialist: specialist,
            createdByAgentId: createdByAgentId,
            attentionRequestKind: attentionRequestKind,
            attentionRequestReason: nil,
            attentionRequestTimestamp: nil,
            pendingQuestionsMessageId: pendingQuestionsMessageId,
            dismissedQuestionsMessageId: dismissedQuestionsMessageId
        )
    }

    // MARK: - Foreground agents

    @Test @MainActor func foregroundAgents_excludesBackground() {
        let viewModel = AgentListViewModel()
        viewModel.agents = [
            makeAgent(id: "fg", name: "Foreground", isBackground: false),
            makeAgent(id: "bg", name: "Background", isBackground: true)
        ]
        #expect(viewModel.foregroundAgents.count == 1)
        #expect(viewModel.foregroundAgents.first?.id == "fg")
    }

    @Test @MainActor func foregroundAgents_coordinatorFirst() {
        let viewModel = AgentListViewModel()
        viewModel.agents = [
            makeAgent(id: "a", name: "Worker", createdAt: "2026-03-15T10:00:00Z", specialist: "implementor"),
            makeAgent(id: "b", name: "Coordinator", createdAt: "2026-03-15T09:00:00Z", specialist: "spec-writer")
        ]
        let ids = viewModel.foregroundAgents.map(\.id)
        #expect(ids == ["b", "a"])
    }

    @Test @MainActor func foregroundAgents_coordinatorFirstEvenWhenStale() {
        let viewModel = AgentListViewModel()
        viewModel.agents = [
            makeAgent(id: "a", name: "Worker", updatedAt: "2026-03-15T12:00:00Z", specialist: "implementor"),
            makeAgent(id: "b", name: "Coordinator", updatedAt: "2026-03-15T08:00:00Z", specialist: "spec-writer")
        ]
        let ids = viewModel.foregroundAgents.map(\.id)
        #expect(ids == ["b", "a"])
    }

    @Test @MainActor func foregroundAgents_sortedByBestTimestampDescending() {
        let viewModel = AgentListViewModel()
        viewModel.agents = [
            makeAgent(id: "created-only", name: "Created Only", createdAt: "2026-03-15T11:00:00Z"),
            makeAgent(id: "updated", name: "Updated", createdAt: "2026-03-15T08:00:00Z", updatedAt: "2026-03-15T12:00:00Z"),
            makeAgent(id: "active", name: "Active", createdAt: "2026-03-15T09:00:00Z", lastActivity: "2026-03-15T10:00:00Z"),
            makeAgent(id: "no-timestamp", name: "No Timestamp")
        ]
        let ids = viewModel.foregroundAgents.map(\.id)
        #expect(ids == ["updated", "created-only", "active", "no-timestamp"])
    }

    @Test @MainActor func foregroundAgents_nilTimestampsLast_tiebreakById() {
        let viewModel = AgentListViewModel()
        viewModel.agents = [
            makeAgent(id: "nil-b", name: "Nil B"),
            makeAgent(id: "nil-a", name: "Nil A"),
            makeAgent(id: "timed", name: "Timed", updatedAt: "2026-03-15T10:00:00Z")
        ]
        let ids = viewModel.foregroundAgents.map(\.id)
        #expect(ids == ["timed", "nil-a", "nil-b"])
    }

    @Test @MainActor func foregroundAgents_equalTimestamps_tiebreakById() {
        let viewModel = AgentListViewModel()
        viewModel.agents = [
            makeAgent(id: "tie-b", name: "Tie B", updatedAt: "2026-03-15T10:00:00Z"),
            makeAgent(id: "tie-a", name: "Tie A", updatedAt: "2026-03-15T10:00:00Z")
        ]
        let ids = viewModel.foregroundAgents.map(\.id)
        #expect(ids == ["tie-a", "tie-b"])
    }

    @Test @MainActor func foregroundAgents_ordersMixedFractionalAndWholeSecondTimestamps() {
        let viewModel = AgentListViewModel()
        viewModel.agents = [
            makeAgent(id: "whole", name: "Whole Second", updatedAt: "2026-03-15T10:00:00Z"),
            makeAgent(id: "fractional", name: "Fractional", updatedAt: "2026-03-15T10:00:00.900Z")
        ]
        let ids = viewModel.foregroundAgents.map(\.id)
        #expect(ids == ["fractional", "whole"])
    }

    // MARK: - Foreground agents: needs-user ordering

    @Test @MainActor func foregroundAgents_needsUserBeatsCoordinator() {
        let viewModel = AgentListViewModel()
        viewModel.agents = [
            makeAgent(id: "coordinator", name: "Coordinator", updatedAt: "2026-03-15T12:00:00Z", specialist: "spec-writer"),
            makeAgent(id: "blocked", name: "Blocked Worker", updatedAt: "2026-03-15T08:00:00Z", specialist: "implementor", attentionRequestKind: "blocker")
        ]
        let ids = viewModel.foregroundAgents.map(\.id)
        #expect(ids == ["blocked", "coordinator"])
    }

    @Test @MainActor func foregroundAgents_needsUserBeatsRecency() {
        let viewModel = AgentListViewModel()
        viewModel.agents = [
            makeAgent(id: "fresh-idle", name: "Fresh Idle", updatedAt: "2026-03-15T12:00:00Z"),
            makeAgent(id: "stale-discussion", name: "Stale Discussion", updatedAt: "2026-03-15T08:00:00Z", attentionRequestKind: "discussion"),
            makeAgent(id: "stale-question", name: "Stale Question", updatedAt: "2026-03-15T07:00:00Z", pendingQuestionsMessageId: "msg-1")
        ]
        let ids = viewModel.foregroundAgents.map(\.id)
        #expect(ids == ["stale-question", "stale-discussion", "fresh-idle"])
    }

    @Test @MainActor func foregroundAgents_needsUserOrder_blockerThenQuestionThenDiscussion() {
        let viewModel = AgentListViewModel()
        // Recency is inverted relative to the expected order so the kind
        // ranking, not the timestamp, decides.
        viewModel.agents = [
            makeAgent(id: "discussion", name: "Discussion", updatedAt: "2026-03-15T12:00:00Z", attentionRequestKind: "discussion"),
            makeAgent(id: "question", name: "Question", updatedAt: "2026-03-15T11:00:00Z", pendingQuestionsMessageId: "msg-1"),
            makeAgent(id: "blocker", name: "Blocker", updatedAt: "2026-03-15T10:00:00Z", attentionRequestKind: "blocker"),
            makeAgent(id: "idle", name: "Idle", updatedAt: "2026-03-15T13:00:00Z")
        ]
        let ids = viewModel.foregroundAgents.map(\.id)
        #expect(ids == ["blocker", "question", "discussion", "idle"])
    }

    @Test @MainActor func foregroundAgents_needsUserTies_fallBackToCoordinatorThenRecency() {
        let viewModel = AgentListViewModel()
        viewModel.agents = [
            makeAgent(id: "worker-old", name: "Worker Old", updatedAt: "2026-03-15T08:00:00Z", specialist: "implementor", attentionRequestKind: "discussion"),
            makeAgent(id: "worker-new", name: "Worker New", updatedAt: "2026-03-15T11:00:00Z", specialist: "implementor", attentionRequestKind: "discussion"),
            makeAgent(id: "coordinator", name: "Coordinator", updatedAt: "2026-03-15T09:00:00Z", specialist: "spec-writer", attentionRequestKind: "discussion")
        ]
        let ids = viewModel.foregroundAgents.map(\.id)
        #expect(ids == ["coordinator", "worker-new", "worker-old"])
    }

    @Test @MainActor func foregroundAgents_dismissedQuestionDoesNotFloat() {
        let viewModel = AgentListViewModel()
        viewModel.agents = [
            makeAgent(id: "dismissed", name: "Dismissed", updatedAt: "2026-03-15T08:00:00Z", pendingQuestionsMessageId: "msg-1", dismissedQuestionsMessageId: "msg-1"),
            makeAgent(id: "cleared", name: "Cleared", updatedAt: "2026-03-15T09:00:00Z", pendingQuestionsMessageId: ""),
            makeAgent(id: "fresh-idle", name: "Fresh Idle", updatedAt: "2026-03-15T12:00:00Z")
        ]
        let ids = viewModel.foregroundAgents.map(\.id)
        #expect(ids == ["fresh-idle", "cleared", "dismissed"])
    }

    @Test @MainActor func foregroundAgents_failedDoesNotFloat() {
        let viewModel = AgentListViewModel()
        viewModel.agents = [
            makeAgent(id: "failed", name: "Failed", status: "error", updatedAt: "2026-03-15T08:00:00Z"),
            makeAgent(id: "fresh-idle", name: "Fresh Idle", updatedAt: "2026-03-15T12:00:00Z")
        ]
        let ids = viewModel.foregroundAgents.map(\.id)
        #expect(ids == ["fresh-idle", "failed"])
    }

    // MARK: - Delegated agents

    @Test @MainActor func delegatedAgents_nestedUnderParent() {
        let viewModel = AgentListViewModel()
        viewModel.agents = [
            makeAgent(id: "parent", name: "Parent"),
            makeAgent(id: "child1", name: "Child 1", createdAt: "2026-03-15T10:00:00Z", createdByAgentId: "parent"),
            makeAgent(id: "child2", name: "Child 2", createdAt: "2026-03-15T11:00:00Z", createdByAgentId: "parent"),
            makeAgent(id: "other", name: "Other Agent")
        ]
        let delegates = viewModel.delegatedAgents(for: "parent")
        #expect(delegates.count == 2)
        // Newest first
        #expect(delegates.first?.id == "child2")
    }

    @Test @MainActor func delegatedAgents_recentActivityBeatsCreation() {
        let viewModel = AgentListViewModel()
        viewModel.agents = [
            makeAgent(id: "parent", name: "Parent"),
            makeAgent(id: "old-but-active", name: "Old but Active", createdAt: "2026-03-15T09:00:00Z", updatedAt: "2026-03-15T12:00:00Z", createdByAgentId: "parent"),
            makeAgent(id: "new-but-idle", name: "New but Idle", createdAt: "2026-03-15T11:00:00Z", createdByAgentId: "parent"),
            makeAgent(id: "no-timestamp", name: "No Timestamp", createdByAgentId: "parent")
        ]
        let ids = viewModel.delegatedAgents(for: "parent").map(\.id)
        #expect(ids == ["old-but-active", "new-but-idle", "no-timestamp"])
    }

    @Test @MainActor func delegatedAgents_needsUserFirstThenRecency() {
        let viewModel = AgentListViewModel()
        viewModel.agents = [
            makeAgent(id: "parent", name: "Parent"),
            makeAgent(id: "fresh-idle", name: "Fresh Idle", updatedAt: "2026-03-15T12:00:00Z", createdByAgentId: "parent"),
            makeAgent(id: "stale-discussion", name: "Stale Discussion", updatedAt: "2026-03-15T08:00:00Z", createdByAgentId: "parent", attentionRequestKind: "discussion"),
            makeAgent(id: "stale-blocker", name: "Stale Blocker", updatedAt: "2026-03-15T07:00:00Z", createdByAgentId: "parent", attentionRequestKind: "blocker"),
            makeAgent(id: "old-idle", name: "Old Idle", updatedAt: "2026-03-15T09:00:00Z", createdByAgentId: "parent")
        ]
        let ids = viewModel.delegatedAgents(for: "parent").map(\.id)
        #expect(ids == ["stale-blocker", "stale-discussion", "fresh-idle", "old-idle"])
    }

    // MARK: - Standalone background agents

    @Test @MainActor func standaloneBackgroundAgents_excludesDelegated() {
        let viewModel = AgentListViewModel()
        viewModel.agents = [
            makeAgent(id: "parent", name: "Parent"),
            makeAgent(id: "bg-delegated", name: "BG Delegated", isBackground: true, createdByAgentId: "parent"),
            makeAgent(id: "bg-standalone", name: "BG Standalone", isBackground: true)
        ]
        let standalone = viewModel.standaloneBackgroundAgents
        #expect(standalone.count == 1)
        #expect(standalone.first?.id == "bg-standalone")
    }

    @Test @MainActor func standaloneBackgroundAgents_includesOrphanedAgents() {
        let viewModel = AgentListViewModel()
        viewModel.agents = [
            makeAgent(id: "parent", name: "Parent"),
            makeAgent(id: "bg-delegated", name: "BG Delegated", isBackground: true, createdByAgentId: "parent"),
            makeAgent(id: "bg-orphaned", name: "BG Orphaned", isBackground: true, createdByAgentId: "deleted-parent"),
            makeAgent(id: "bg-standalone", name: "BG Standalone", isBackground: true)
        ]
        let standalone = viewModel.standaloneBackgroundAgents
        let ids = Set(standalone.map { $0.id })
        #expect(ids.count == 2)
        #expect(ids.contains("bg-standalone"))
        #expect(ids.contains("bg-orphaned"))
        #expect(!ids.contains("bg-delegated"))
    }

    @Test @MainActor func standaloneBackgroundAgents_sortedByBestTimestampDescending() {
        let viewModel = AgentListViewModel()
        viewModel.agents = [
            makeAgent(id: "bg-created", name: "BG Created", isBackground: true, createdAt: "2026-03-15T11:00:00Z"),
            makeAgent(id: "bg-active", name: "BG Active", isBackground: true, createdAt: "2026-03-15T08:00:00Z", lastActivity: "2026-03-15T12:00:00Z"),
            makeAgent(id: "bg-nil", name: "BG Nil", isBackground: true)
        ]
        let ids = viewModel.standaloneBackgroundAgents.map(\.id)
        #expect(ids == ["bg-active", "bg-created", "bg-nil"])
    }

    @Test @MainActor func standaloneBackgroundAgents_needsUserFirstThenRecency() {
        let viewModel = AgentListViewModel()
        viewModel.agents = [
            makeAgent(id: "bg-fresh", name: "BG Fresh", isBackground: true, updatedAt: "2026-03-15T12:00:00Z"),
            makeAgent(id: "bg-question", name: "BG Question", isBackground: true, updatedAt: "2026-03-15T07:00:00Z", pendingQuestionsMessageId: "msg-1"),
            makeAgent(id: "bg-old", name: "BG Old", isBackground: true, updatedAt: "2026-03-15T09:00:00Z"),
            makeAgent(id: "bg-orphaned-blocker", name: "BG Orphaned Blocker", isBackground: true, updatedAt: "2026-03-15T06:00:00Z", createdByAgentId: "deleted-parent", attentionRequestKind: "blocker")
        ]
        let ids = viewModel.standaloneBackgroundAgents.map(\.id)
        #expect(ids == ["bg-orphaned-blocker", "bg-question", "bg-fresh", "bg-old"])
    }

    // MARK: - AgentSession computed properties

    @Test func agentSession_isActive_forActiveStatus() {
        let agent = makeAgent(status: "active")
        #expect(agent.isActive == true)
    }

    @Test func agentSession_isActive_forStreamingAgent() {
        let agent = makeAgent(status: "Idle", isStreaming: true)
        #expect(agent.isActive == true)
    }

    @Test func agentSession_isActive_falseForIdle() {
        let agent = makeAgent(status: "Idle")
        #expect(agent.isActive == false)
    }

    @Test func agentSession_displayMessage_prefersDigest() {
        let agent = makeAgent(lastAgentResponse: "long response", digest: "short digest")
        #expect(agent.displayMessage == "short digest")
    }

    @Test func agentSession_displayMessage_fallsBackToResponse() {
        let agent = makeAgent(lastAgentResponse: "response text")
        #expect(agent.displayMessage == "response text")
    }

    @Test func agentSession_bestTimestamp_prefersLastActivity() {
        let agent = makeAgent(
            updatedAt: "2026-03-15T12:00:00Z",
            lastActivity: "2026-03-15T11:00:00Z"
        )
        #expect(agent.bestTimestamp == "2026-03-15T11:00:00Z")
    }

    @Test func agentSession_bestTimestamp_fallbackChain() {
        let agent1 = makeAgent(updatedAt: "2026-03-15T11:00:00Z")
        #expect(agent1.bestTimestamp == "2026-03-15T11:00:00Z")

        let agent2 = makeAgent(createdAt: "2026-03-15T10:00:00Z")
        #expect(agent2.bestTimestamp == "2026-03-15T10:00:00Z")

        let agent3 = makeAgent()
        #expect(agent3.bestTimestamp == nil)
    }
}
