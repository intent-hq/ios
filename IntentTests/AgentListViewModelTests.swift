import Testing
@testable import Intent

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
        createdByAgentId: String? = nil
    ) -> AgentSession {
        AgentSession(
            id: id, name: name, status: status,
            isBackground: isBackground, isStreaming: isStreaming,
            isProcessing: isProcessing, isResponding: isResponding,
            isWaitingForOtherAgents: false, waitingForAgentIds: [],
            createdAt: createdAt, updatedAt: updatedAt,
            lastActivity: lastActivity,
            lastAgentResponse: lastAgentResponse,
            lastUserMessage: nil, lastMessageRole: nil, digest: digest,
            specialist: specialist,
            createdByAgentId: createdByAgentId,
            attentionRequestKind: nil,
            attentionRequestReason: nil,
            attentionRequestTimestamp: nil
        )
    }

    // MARK: - Foreground agents

    @Test @MainActor func foregroundAgents_excludesBackground() {
        let vm = AgentListViewModel()
        vm.agents = [
            makeAgent(id: "fg", name: "Foreground", isBackground: false),
            makeAgent(id: "bg", name: "Background", isBackground: true),
        ]
        #expect(vm.foregroundAgents.count == 1)
        #expect(vm.foregroundAgents.first?.id == "fg")
    }

    @Test @MainActor func foregroundAgents_coordinatorFirst() {
        let vm = AgentListViewModel()
        vm.agents = [
            makeAgent(id: "a", name: "Worker", createdAt: "2026-03-15T10:00:00Z", specialist: "implementor"),
            makeAgent(id: "b", name: "Coordinator", createdAt: "2026-03-15T09:00:00Z", specialist: "spec-writer"),
        ]
        let ids = vm.foregroundAgents.map(\.id)
        #expect(ids == ["b", "a"])
    }

    @Test @MainActor func foregroundAgents_coordinatorFirstEvenWhenStale() {
        let vm = AgentListViewModel()
        vm.agents = [
            makeAgent(id: "a", name: "Worker", updatedAt: "2026-03-15T12:00:00Z", specialist: "implementor"),
            makeAgent(id: "b", name: "Coordinator", updatedAt: "2026-03-15T08:00:00Z", specialist: "spec-writer"),
        ]
        let ids = vm.foregroundAgents.map(\.id)
        #expect(ids == ["b", "a"])
    }

    @Test @MainActor func foregroundAgents_sortedByBestTimestampDescending() {
        let vm = AgentListViewModel()
        vm.agents = [
            makeAgent(id: "created-only", name: "Created Only", createdAt: "2026-03-15T11:00:00Z"),
            makeAgent(id: "updated", name: "Updated", createdAt: "2026-03-15T08:00:00Z", updatedAt: "2026-03-15T12:00:00Z"),
            makeAgent(id: "active", name: "Active", createdAt: "2026-03-15T09:00:00Z", lastActivity: "2026-03-15T10:00:00Z"),
            makeAgent(id: "no-timestamp", name: "No Timestamp"),
        ]
        let ids = vm.foregroundAgents.map(\.id)
        #expect(ids == ["updated", "created-only", "active", "no-timestamp"])
    }

    @Test @MainActor func foregroundAgents_nilTimestampsLast_tiebreakById() {
        let vm = AgentListViewModel()
        vm.agents = [
            makeAgent(id: "nil-b", name: "Nil B"),
            makeAgent(id: "nil-a", name: "Nil A"),
            makeAgent(id: "timed", name: "Timed", updatedAt: "2026-03-15T10:00:00Z"),
        ]
        let ids = vm.foregroundAgents.map(\.id)
        #expect(ids == ["timed", "nil-a", "nil-b"])
    }

    @Test @MainActor func foregroundAgents_equalTimestamps_tiebreakById() {
        let vm = AgentListViewModel()
        vm.agents = [
            makeAgent(id: "tie-b", name: "Tie B", updatedAt: "2026-03-15T10:00:00Z"),
            makeAgent(id: "tie-a", name: "Tie A", updatedAt: "2026-03-15T10:00:00Z"),
        ]
        let ids = vm.foregroundAgents.map(\.id)
        #expect(ids == ["tie-a", "tie-b"])
    }

    @Test @MainActor func foregroundAgents_ordersMixedFractionalAndWholeSecondTimestamps() {
        let vm = AgentListViewModel()
        vm.agents = [
            makeAgent(id: "whole", name: "Whole Second", updatedAt: "2026-03-15T10:00:00Z"),
            makeAgent(id: "fractional", name: "Fractional", updatedAt: "2026-03-15T10:00:00.900Z"),
        ]
        let ids = vm.foregroundAgents.map(\.id)
        #expect(ids == ["fractional", "whole"])
    }

    // MARK: - Delegated agents

    @Test @MainActor func delegatedAgents_nestedUnderParent() {
        let vm = AgentListViewModel()
        vm.agents = [
            makeAgent(id: "parent", name: "Parent"),
            makeAgent(id: "child1", name: "Child 1", createdAt: "2026-03-15T10:00:00Z", createdByAgentId: "parent"),
            makeAgent(id: "child2", name: "Child 2", createdAt: "2026-03-15T11:00:00Z", createdByAgentId: "parent"),
            makeAgent(id: "other", name: "Other Agent"),
        ]
        let delegates = vm.delegatedAgents(for: "parent")
        #expect(delegates.count == 2)
        // Newest first
        #expect(delegates.first?.id == "child2")
    }

    @Test @MainActor func delegatedAgents_recentActivityBeatsCreation() {
        let vm = AgentListViewModel()
        vm.agents = [
            makeAgent(id: "parent", name: "Parent"),
            makeAgent(id: "old-but-active", name: "Old but Active", createdAt: "2026-03-15T09:00:00Z", updatedAt: "2026-03-15T12:00:00Z", createdByAgentId: "parent"),
            makeAgent(id: "new-but-idle", name: "New but Idle", createdAt: "2026-03-15T11:00:00Z", createdByAgentId: "parent"),
            makeAgent(id: "no-timestamp", name: "No Timestamp", createdByAgentId: "parent"),
        ]
        let ids = vm.delegatedAgents(for: "parent").map(\.id)
        #expect(ids == ["old-but-active", "new-but-idle", "no-timestamp"])
    }

    // MARK: - Standalone background agents

    @Test @MainActor func standaloneBackgroundAgents_excludesDelegated() {
        let vm = AgentListViewModel()
        vm.agents = [
            makeAgent(id: "parent", name: "Parent"),
            makeAgent(id: "bg-delegated", name: "BG Delegated", isBackground: true, createdByAgentId: "parent"),
            makeAgent(id: "bg-standalone", name: "BG Standalone", isBackground: true),
        ]
        let standalone = vm.standaloneBackgroundAgents
        #expect(standalone.count == 1)
        #expect(standalone.first?.id == "bg-standalone")
    }

    @Test @MainActor func standaloneBackgroundAgents_includesOrphanedAgents() {
        let vm = AgentListViewModel()
        vm.agents = [
            makeAgent(id: "parent", name: "Parent"),
            makeAgent(id: "bg-delegated", name: "BG Delegated", isBackground: true, createdByAgentId: "parent"),
            makeAgent(id: "bg-orphaned", name: "BG Orphaned", isBackground: true, createdByAgentId: "deleted-parent"),
            makeAgent(id: "bg-standalone", name: "BG Standalone", isBackground: true),
        ]
        let standalone = vm.standaloneBackgroundAgents
        let ids = Set(standalone.map { $0.id })
        #expect(ids.count == 2)
        #expect(ids.contains("bg-standalone"))
        #expect(ids.contains("bg-orphaned"))
        #expect(!ids.contains("bg-delegated"))
    }

    @Test @MainActor func standaloneBackgroundAgents_sortedByBestTimestampDescending() {
        let vm = AgentListViewModel()
        vm.agents = [
            makeAgent(id: "bg-created", name: "BG Created", isBackground: true, createdAt: "2026-03-15T11:00:00Z"),
            makeAgent(id: "bg-active", name: "BG Active", isBackground: true, createdAt: "2026-03-15T08:00:00Z", lastActivity: "2026-03-15T12:00:00Z"),
            makeAgent(id: "bg-nil", name: "BG Nil", isBackground: true),
        ]
        let ids = vm.standaloneBackgroundAgents.map(\.id)
        #expect(ids == ["bg-active", "bg-created", "bg-nil"])
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

    @Test func agentSession_bestTimestamp_prefersUpdatedAt() {
        let agent = makeAgent(
            updatedAt: "2026-03-15T12:00:00Z",
            lastActivity: "2026-03-15T11:00:00Z"
        )
        #expect(agent.bestTimestamp == "2026-03-15T12:00:00Z")
    }

    @Test func agentSession_bestTimestamp_fallbackChain() {
        let agent1 = makeAgent(lastActivity: "2026-03-15T11:00:00Z")
        #expect(agent1.bestTimestamp == "2026-03-15T11:00:00Z")

        let agent2 = makeAgent(createdAt: "2026-03-15T10:00:00Z")
        #expect(agent2.bestTimestamp == "2026-03-15T10:00:00Z")

        let agent3 = makeAgent()
        #expect(agent3.bestTimestamp == nil)
    }
}

