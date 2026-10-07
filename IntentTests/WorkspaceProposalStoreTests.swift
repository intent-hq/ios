import Foundation
@testable import Intent
import Testing

@MainActor
struct WorkspaceProposalStoreTests {
    private func connection(messageId: String = "message") -> FakeConnectionManager {
        let connection = FakeConnectionManager()
        connection.connectionState = .connected
        connection.responseMap["agent.get"] = [
            "agent": ["metadata": ["pendingProposals": [["proposalId": "proposal", "messageId": messageId]]]]
        ]
        connection.responseMap["workspace.create"] = ["workspace": ["id": "created", "title": "Created workspace"]]
        connection.responseMap["agent.resolveProposal"] = ["success": true, "outcome": "applied"]
        return connection
    }

    private func store(_ connection: FakeConnectionManager, workspaces: WorkspaceStore? = nil) -> ProposalActionStore {
        ProposalActionStore(connection: connection, agentId: "agent", workspaceId: "source", workspaceStore: workspaces)
    }

    private func apply(_ proposal: ActionProposal, to store: ProposalActionStore, title: String = "Reviewed title") async {
        await store.createWorkspace(proposal, messageId: "message", edits: .init(title: title, initialPrompt: "Reviewed instructions"))
    }

    @Test func createsThenResolvesAndPublishesToCurrentSession() async throws {
        let connection = connection()
        let workspaces = WorkspaceStore(forTesting: true)
        let store = store(connection, workspaces: workspaces)
        let proposal = try WorkspaceProposalFixture.proposal()
        await apply(proposal, to: store)
        #expect(store.resolutions[proposal.id] == "applied")
        #expect(store.createdWorkspaces[store.receiptKey(proposal, messageId: "message")]?.id == "created")
        #expect(workspaces.workspaces.contains { $0.id == "created" })
        let request = try #require(connection.paramsForMethod("workspace.create").first)
        #expect(request["title"] as? String == "Reviewed title")
        #expect(request["idempotencyKey"] as? String == "shared-proposal-key")
        #expect(connection.paramsForMethod("agent.resolveProposal").first?["workspaceId"] as? String == "source")
        #expect(connection.paramsForMethod("agent.resolveProposal").first?["detail"] as? String == "Created workspace created.")
        #expect(!store.isBusy)
    }

    @Test func retryReusesOriginalRequestAfterLostResponse() async throws {
        let connection = connection()
        connection.errorMap["workspace.create"] = NSError(domain: "LostResponse", code: 1)
        let store = store(connection)
        let proposal = try WorkspaceProposalFixture.proposal()
        await apply(proposal, to: store)
        #expect(!connection.didCallMethod("agent.resolveProposal"))
        #expect(store.errors[proposal.id] != nil)
        connection.errorMap.removeValue(forKey: "workspace.create")
        await apply(proposal, to: store, title: "Changed after failure")
        let requests = connection.paramsForMethod("workspace.create")
        #expect(requests.count == 2)
        #expect(AnyCodable(requests[0]) == AnyCodable(requests[1]))
        #expect(store.resolutions[proposal.id] == "applied")
        #expect(store.errors[proposal.id] == nil)
    }

    @Test func confirmationRetryDoesNotCreateAgain() async throws {
        let connection = connection()
        connection.errorMap["agent.resolveProposal"] = NSError(domain: "Resolution", code: 1)
        let store = store(connection)
        let proposal = try WorkspaceProposalFixture.proposal()
        await apply(proposal, to: store)
        #expect(store.createdWorkspaces[store.receiptKey(proposal, messageId: "message")] != nil)
        #expect(store.errors[proposal.id]?.contains("Workspace created") == true)
        connection.errorMap.removeValue(forKey: "agent.resolveProposal")
        await apply(proposal, to: store)
        #expect(connection.paramsForMethod("workspace.create").count == 1)
        #expect(store.resolutions[proposal.id] == "applied")
    }

    @Test func rejectedCreationAllowsCorrectionAndDismissal() async throws {
        let connection = connection()
        connection.errorMap["workspace.create"] = NSError(domain: "WebSocket", code: -32_602)
        let store = store(connection)
        let proposal = try WorkspaceProposalFixture.proposal()
        await apply(proposal, to: store)
        #expect(!store.hasCreationAttempt(proposal, messageId: "message"))
        #expect(store.submittedEdits(proposal, messageId: "message") == nil)
        await apply(proposal, to: store, title: "Corrected title")
        #expect(connection.paramsForMethod("workspace.create").last?["title"] as? String == "Corrected title")
        connection.responseMap["agent.resolveProposal"] = ["success": true, "outcome": "dismissed"]
        await store.dismiss(proposal, messageId: "message")
        #expect(store.resolutions[proposal.id] == "dismissed")
    }

    @Test func transportAndMetadataErrorsKeepUncertainRequestLocked() async throws {
        let connection = connection()
        connection.errorMap["workspace.create"] = NSError(domain: NSURLErrorDomain, code: -32_602)
        let store = store(connection)
        let proposal = try WorkspaceProposalFixture.proposal()
        await apply(proposal, to: store)
        #expect(store.hasCreationAttempt(proposal, messageId: "message"))
        connection.errorMap["agent.get"] = NSError(domain: "WebSocket", code: -32_602)
        await apply(proposal, to: store)
        #expect(store.hasCreationAttempt(proposal, messageId: "message"))
    }

    @Test func fallbackKeySurvivesStoreRecreation() async throws {
        let connection = connection()
        connection.responseMap["workspace.create"] = [:] as [String: Any]
        let proposal = try WorkspaceProposalFixture.proposal(params: ["idempotencyKey": NSNull()])
        await apply(proposal, to: store(connection))
        await apply(proposal, to: store(connection))
        let requests = connection.paramsForMethod("workspace.create")
        let first = try #require(requests.first?["idempotencyKey"] as? String)
        #expect(!first.isEmpty)
        #expect(requests.last?["idempotencyKey"] as? String == first)
        #expect(!connection.didCallMethod("agent.resolveProposal"))
    }

    @Test func staleAndResolvedCardsCannotCreate() async throws {
        let connection = connection(messageId: "new-message")
        let store = store(connection)
        let proposal = try WorkspaceProposalFixture.proposal()
        await apply(proposal, to: store)
        connection.responseMap["agent.get"] = ["agent": ["metadata": ["proposalResolutions": ["proposal": "dismissed"]]]]
        await apply(proposal, to: store)
        #expect(!connection.didCallMethod("workspace.create"))
        #expect(!connection.didCallMethod("agent.resolveProposal"))
    }

    @Test func dismissCreatesNothing() async throws {
        let connection = connection()
        connection.responseMap["agent.resolveProposal"] = ["success": true, "outcome": "dismissed"]
        let store = store(connection)
        await store.dismiss(try WorkspaceProposalFixture.proposal(), messageId: "message")
        #expect(!connection.didCallMethod("workspace.create"))
        #expect(store.resolutions["proposal"] == "dismissed")
    }

    @Test func uncertainCreationCannotBeDismissed() async throws {
        let connection = connection()
        connection.errorMap["workspace.create"] = NSError(domain: "LostResponse", code: 1)
        let store = store(connection)
        let proposal = try WorkspaceProposalFixture.proposal()
        await apply(proposal, to: store)
        await store.dismiss(proposal, messageId: "message")
        #expect(!connection.didCallMethod("agent.resolveProposal"))
        #expect(store.isPending(proposal, messageId: "message"))
    }

    @Test func concurrentDismissalKeepsCreatedWorkspaceAvailable() async throws {
        let connection = connection()
        connection.responseMap["agent.resolveProposal"] = ["success": true, "outcome": "dismissed"]
        let store = store(connection)
        let proposal = try WorkspaceProposalFixture.proposal()
        await apply(proposal, to: store)
        #expect(store.resolutions[proposal.id] == "dismissed")
        #expect(store.createdWorkspaces[store.receiptKey(proposal, messageId: "message")]?.id == "created")
    }

    @Test func repeatedTapCannotStartSecondCreation() async throws {
        let connection = connection()
        connection.pendingMethods = ["workspace.create"]
        let store = store(connection)
        let proposal = try WorkspaceProposalFixture.proposal()
        let first = Task { await apply(proposal, to: store) }
        defer { first.cancel() }
        try await connection.waitForPendingRequests("workspace.create")
        await apply(proposal, to: store)
        #expect(connection.paramsForMethod("workspace.create").count == 1)
        connection.resolvePending("workspace.create", with: ["workspace": ["id": "created", "title": "Created"]])
        await first.value
        #expect(store.resolutions[proposal.id] == "applied")
    }

    @Test func missingAuthorityOrDisconnectedSessionCannotCreate() async throws {
        let connection = connection()
        let store = store(connection)
        let proposal = try WorkspaceProposalFixture.proposal()
        connection.currentPrincipal = nil
        await apply(proposal, to: store)
        connection.currentPrincipal = .demoOwner
        connection.connectionState = .disconnected
        await apply(proposal, to: store)
        #expect(!connection.didCallMethod("workspace.create"))
    }
}
