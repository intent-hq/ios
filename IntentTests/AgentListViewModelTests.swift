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
            lastUserMessage: nil, digest: digest,
            specialist: specialist,
            createdByAgentId: createdByAgentId
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

