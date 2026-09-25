import Foundation
@testable import Intent
import Testing

@MainActor
struct ProposalActionStoreTests {
    private func proposal(operation: String = "workspace.bulkArchive") -> ActionProposal {
        ActionProposal(
            kind: "bulk-op", payload: ["operation": AnyCodable(operation), "ids": AnyCodable(["alpha", "beta"])],
            preview: .init(title: "Archive workspaces", summary: nil, applyLabel: "Archive", bulkItems: [], warnings: []),
            applyToolCallId: "proposal"
        )
    }

    private func connection(messageId: String = "message") -> FakeConnectionManager {
        let connection = FakeConnectionManager()
        connection.responseMap["agent.get"] = ["agent": ["metadata": [
            "pendingProposals": [["proposalId": "proposal", "messageId": messageId]]
        ]]]
        connection.responseMap["workspace.archive"] = ["workspace": ["id": "alpha"]]
        connection.responseMap["workspace.delete"] = ["success": true]
        connection.responseMap["agent.resolveProposal"] = ["success": true, "outcome": "applied"]
        return connection
    }

    private func store(_ connection: FakeConnectionManager) -> ProposalActionStore {
        ProposalActionStore(connection: connection, agentId: "assistant", workspaceId: "__chief__")
    }

    @Test func onlyAppliesSelectedPayloadIDsThenResolves() async {
        let connection = connection()
        let store = store(connection)
        await store.apply(proposal(), messageId: "message", selection: ["beta", "injected"])
        #expect(connection.paramsForMethod("workspace.archive").compactMap { $0["workspaceId"] as? String } == ["beta"])
        #expect(store.resolutions["proposal"] == "applied")
        #expect(connection.paramsForMethod("agent.resolveProposal").first?["workspaceId"] as? String == "__chief__")
    }

    @Test func staleMessageCannotApplyOrDismiss() async {
        let connection = connection(messageId: "new-message")
        let store = store(connection)
        await store.apply(proposal(), messageId: "old-message", selection: ["alpha"])
        await store.dismiss(proposal(), messageId: "old-message")
        #expect(!connection.didCallMethod("workspace.archive"))
        #expect(!connection.didCallMethod("agent.resolveProposal"))
    }

    @Test func alreadyResolvedProposalCannotApply() async {
        let connection = connection()
        connection.responseMap["agent.get"] = ["agent": ["metadata": ["proposalResolutions": ["proposal": "dismissed"]]]]
        let store = store(connection)
        await store.apply(proposal(), messageId: "message", selection: ["alpha"])
        #expect(!connection.didCallMethod("workspace.archive"))
        #expect(store.resolutions["proposal"] == "dismissed")
    }

    @Test func failedMutationDoesNotResolve() async {
        let connection = connection()
        connection.errorMap["workspace.archive"] = NSError(domain: "Test", code: 1)
        let store = store(connection)
        await store.apply(proposal(), messageId: "message", selection: ["alpha"])
        #expect(!connection.didCallMethod("agent.resolveProposal"))
        #expect(store.errors["proposal"] != nil)
        #expect(!store.isBusy)
    }

    @Test func partialFailureRetriesOnlyRemainingItems() async {
        let connection = connection()
        connection.responseQueueMap["workspace.archive"] = [["workspace": ["id": "alpha"]], [:] as [String: Any]]
        let store = store(connection)
        await store.apply(proposal(), messageId: "message", selection: ["alpha", "beta"])
        #expect(!connection.didCallMethod("agent.resolveProposal"))
        await store.apply(proposal(), messageId: "message", selection: ["alpha", "beta"])
        #expect(connection.paramsForMethod("workspace.archive").compactMap { $0["workspaceId"] as? String } == ["alpha", "beta", "beta"])
        #expect(store.resolutions["proposal"] == "applied")
    }

    @Test func decodesCanonicalProposalResourceButNotQuestions() throws {
        let json = """
        {"kind":"bulk-op","payload":{"operation":"workspace.bulkArchive","ids":["alpha"]},
         "preview":{"title":"Archive","bulkItems":[{"id":"alpha","title":"Alpha","disabled":true}]}}
        """
        let block = ContentBlock(id: "resource", type: .resource, resource: .init(uri: nil, mimeType: "application/vnd.intent.proposal+json", text: json))
        let proposal = try #require(ActionProposal.parse(block))
        #expect(proposal.initialSelection.isEmpty)
        #expect(proposal.selectableIDs.isEmpty)
        #expect(proposal.id == "Archive")
        let question = ContentBlock(id: "question", type: .resource, resource: .init(uri: nil, mimeType: "application/vnd.intent.questions+json", text: json))
        #expect(ActionProposal.parse(question) == nil)
    }

    @Test func resolutionRetryDoesNotRepeatSuccessfulMutation() async {
        let connection = connection()
        connection.errorMap["agent.resolveProposal"] = NSError(domain: "Test", code: 1)
        let store = store(connection)
        await store.apply(proposal(), messageId: "message", selection: ["alpha"])
        connection.errorMap.removeValue(forKey: "agent.resolveProposal")
        await store.apply(proposal(), messageId: "message", selection: ["alpha"])
        #expect(connection.paramsForMethod("workspace.archive").count == 1)
        #expect(store.resolutions["proposal"] == "applied")
    }

    @Test func dismissOnlyRecordsOutcome() async {
        let connection = connection()
        connection.responseMap["agent.resolveProposal"] = ["success": true, "outcome": "dismissed"]
        let store = store(connection)
        await store.dismiss(proposal(), messageId: "message")
        #expect(store.resolutions["proposal"] == "dismissed")
        #expect(!connection.didCallMethod("workspace.archive"))
    }

    @Test func rejectsUnknownOperationsAndEmptySelection() async {
        let connection = connection()
        let store = store(connection)
        await store.apply(proposal(operation: "arbitrary.method"), messageId: "message", selection: ["alpha"])
        await store.apply(proposal(), messageId: "message", selection: [])
        #expect(!connection.didCallMethod("agent.get"))
    }

    @Test func deleteUsesExplicitDeleteMethod() async {
        let connection = connection()
        await store(connection).apply(proposal(operation: "workspace.bulkDelete"), messageId: "message", selection: ["alpha"])
        #expect(connection.paramsForMethod("workspace.delete").count == 1)
        #expect(!connection.didCallMethod("workspace.archive"))
    }
}
