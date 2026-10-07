import Foundation
@testable import Intent
import Testing

enum WorkspaceProposalFixture {
    static func proposal(params: [String: Any] = [:], sibling: Bool = true) throws -> ActionProposal {
        var request: [String: Any] = [
            "title": "Investigate Mermaid tests", "repositoryPath": "/repos/intent", "baseRef": "main",
            "idempotencyKey": "shared-proposal-key",
            "initialAgent": ["name": "Implementor", "prompt": "Investigate the failures", "specialist": "implementor"]
        ]
        request.merge(params) { _, new in new }
        let wire: [String: Any] = [
            "kind": "workspace-create", "applyToolCallId": "proposal",
            "payload": ["operation": "workspace.create", "params": request],
            "preview": [
                "title": "Create workspace: Investigate Mermaid tests",
                "workspaceCreate": ["mode": sibling ? "sibling" : "", "githubUrl": "https://github.com/intent-hq/intent"]
            ]
        ]
        return try JSONDecoder().decode(ActionProposal.self, from: JSONSerialization.data(withJSONObject: wire))
    }
}

@MainActor
struct WorkspaceCreationProposalTests {
    @Test func siblingEditsPreserveRepositoryAndAgentSettings() throws {
        let proposal = try WorkspaceProposalFixture.proposal(params: [
            "repositoryOwner": "intent-hq", "repositoryName": "intent",
            "initialAgent": [
                "agentId": "must-not-send", "name": "Implementor", "prompt": "Original",
                "specialist": "implementor", "provider": "codex", "model": "chosen-model",
                "metadata": ["custom": "kept"]
            ]
        ])
        let creation = try #require(proposal.workspaceCreation)
        let request = try creation.request(edits: .init(title: " New title ", initialPrompt: " New instructions "), fallbackKey: "unused")
        #expect(request["title"] as? String == "New title")
        #expect(request["repositoryPath"] as? String == "/repos/intent")
        #expect(request["repositoryOwner"] as? String == "intent-hq")
        #expect(request["baseRef"] as? String == "main")
        #expect(request["githubUrl"] == nil)
        #expect(request["idempotencyKey"] as? String == "shared-proposal-key")
        let agent = try #require(request["initialAgent"] as? [String: Any])
        #expect(agent["prompt"] as? String == "New instructions")
        #expect(agent["agentId"] == nil)
        #expect(agent["provider"] as? String == "codex")
        #expect(agent["model"] as? String == "chosen-model")
        #expect(agent["specialist"] as? String == "implementor")
        #expect(agent["agentType"] as? String == "workspace")
        let metadata = try #require(agent["metadata"] as? [String: Any])
        #expect(metadata["custom"] as? String == "kept")
        #expect(metadata["isInitialAgent"] as? Bool == true)
    }

    @Test func githubPickDropsLocalPathButExplicitCloneRetainsIt() throws {
        let params: [String: Any] = ["githubUrl": "https://github.com/intent-hq/intent", "prNumber": 42]
        let pick = try #require(WorkspaceProposalFixture.proposal(params: params, sibling: false).workspaceCreation)
        let request = try pick.request(edits: pick.edits, fallbackKey: "fallback")
        #expect(request["repositoryPath"] == nil)
        #expect(request["clonePath"] == nil)
        #expect(request["prNumber"] as? Int == 42)
        let clone = try #require(WorkspaceProposalFixture.proposal(
            params: params.merging(["clonePath": "/repos/intent"]) { _, new in new }, sibling: false
        ).workspaceCreation)
        let cloneRequest = try clone.request(edits: clone.edits, fallbackKey: "fallback")
        #expect(cloneRequest["clonePath"] as? String == "/repos/intent")
        #expect(cloneRequest["repositoryPath"] as? String == "/repos/intent")
    }

    @Test func legacyPromptAndMissingKeyUseStableFallback() throws {
        let creation = try #require(WorkspaceProposalFixture.proposal(params: [
            "initialAgent": NSNull(), "message": "Legacy instructions", "idempotencyKey": NSNull()
        ]).workspaceCreation)
        #expect(creation.initialPrompt == "Legacy instructions")
        let request = try creation.request(edits: creation.edits, fallbackKey: "stable-key")
        #expect(request["idempotencyKey"] as? String == "stable-key")
        #expect((request["initialAgent"] as? [String: Any])?["prompt"] as? String == "Legacy instructions")
    }

    @Test func missingRepositoryCannotCreate() throws {
        let creation = try #require(WorkspaceProposalFixture.proposal(params: ["repositoryPath": NSNull()]).workspaceCreation)
        #expect(throws: WorkspaceProposalError.self) {
            try creation.request(edits: creation.edits, fallbackKey: "key")
        }
    }

    @Test func newBranchDoesNotBecomeTheBaseReference() throws {
        let creation = try #require(WorkspaceProposalFixture.proposal(params: ["branch": "feat/follow-up", "baseRef": NSNull()]).workspaceCreation)
        let request = try creation.request(edits: creation.edits, fallbackKey: "key")
        #expect(request["branch"] as? String == "feat/follow-up")
        #expect(request["baseRef"] as? String == nil)
    }

    @Test func chiefPreviewSuppliesLegacyPromptAndSpecialist() throws {
        let json = """
        {"kind":"workspace-create","payload":{"operation":"workspace.create","params":{"githubUrl":"https://github.com/intent-hq/intent"}},
         "preview":{"title":"Create workspace","workspaceCreate":{"initialPrompt":"Fix the tests","specialist":"implementor"}}}
        """
        let proposal = try JSONDecoder().decode(ActionProposal.self, from: Data(json.utf8))
        let creation = try #require(proposal.workspaceCreation)
        let request = try creation.request(edits: creation.edits, fallbackKey: "key")
        let agent = try #require(request["initialAgent"] as? [String: Any])
        #expect(agent["prompt"] as? String == "Fix the tests")
        #expect(agent["specialist"] as? String == "implementor")
        #expect(request["title"] == nil)
    }

    @Test func neverDispatchesAnArbitraryProposalOperation() throws {
        let original = try WorkspaceProposalFixture.proposal()
        let proposal = ActionProposal(
            kind: original.kind,
            payload: ["operation": AnyCodable("arbitrary.method")],
            preview: original.preview,
            applyToolCallId: original.applyToolCallId
        )
        #expect(proposal.workspaceCreation == nil)
    }
}
