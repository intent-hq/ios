import Foundation
import Testing
@testable import Intent

struct ModelsTests {
    @Test func pairedServerCodable() async throws {
        let server = PairedServer(hosts: ["192.168.1.1"], port: 3000, name: "My Mac", pairedAt: Date(timeIntervalSince1970: 1000))
        let data = try JSONEncoder().encode(server)
        let decoded = try JSONDecoder().decode(PairedServer.self, from: data)
        #expect(decoded == server)
    }

    @Test func pairedServerCodableWithFingerprint() async throws {
        let server = PairedServer(
            hosts: ["192.168.1.1"], port: 3000, name: "My Mac",
            pairedAt: Date(timeIntervalSince1970: 1000),
            certFingerprint: "AA:BB:CC:DD:EE:FF"
        )
        let data = try JSONEncoder().encode(server)
        let decoded = try JSONDecoder().decode(PairedServer.self, from: data)
        #expect(decoded == server)
        #expect(decoded.certFingerprint == "AA:BB:CC:DD:EE:FF")
    }

    @Test func pairedServerCodableWithoutFingerprint() async throws {
        let server = PairedServer(
            hosts: ["192.168.1.1"], port: 3000, name: "My Mac",
            pairedAt: Date(timeIntervalSince1970: 1000)
        )
        let data = try JSONEncoder().encode(server)
        let decoded = try JSONDecoder().decode(PairedServer.self, from: data)
        #expect(decoded == server)
        #expect(decoded.certFingerprint == nil)
    }

    @Test func pairedServerCodableMultipleHosts() async throws {
        let server = PairedServer(
            hosts: ["192.168.1.1", "100.64.0.1"], port: 3000, name: "My Mac",
            pairedAt: Date(timeIntervalSince1970: 1000)
        )
        let data = try JSONEncoder().encode(server)
        let decoded = try JSONDecoder().decode(PairedServer.self, from: data)
        #expect(decoded == server)
        #expect(decoded.hosts.count == 2)
        #expect(decoded.hosts[0] == "192.168.1.1")
        #expect(decoded.hosts[1] == "100.64.0.1")
    }

    @Test func workspaceEquality() async throws {
        let ws1 = Workspace(id: "1", title: "Test", branch: "main", baseRef: nil, status: "Active", activity: nil, displayStatus: nil, lastActivity: nil, updatedAt: nil, repositoryOwner: "org", repositoryName: "repo", prStatus: nil, prNumber: nil, diffSummaryTotalFiles: nil, taskStatsTotal: nil, taskStatsCompleted: nil, taskStatsInProgress: nil, agentSummaryCount: nil, agentSummaryAgents: nil)
        let ws2 = Workspace(id: "1", title: "Test", branch: "main", baseRef: nil, status: "Active", activity: nil, displayStatus: nil, lastActivity: nil, updatedAt: nil, repositoryOwner: "org", repositoryName: "repo", prStatus: nil, prNumber: nil, diffSummaryTotalFiles: nil, taskStatsTotal: nil, taskStatsCompleted: nil, taskStatsInProgress: nil, agentSummaryCount: nil, agentSummaryAgents: nil)
        #expect(ws1 == ws2)
    }

    @Test func workspaceInequalityDifferentId() async throws {
        let ws1 = Workspace(id: "1", title: "Test", branch: nil, baseRef: nil, status: nil, activity: nil, displayStatus: nil, lastActivity: nil, updatedAt: nil, repositoryOwner: nil, repositoryName: nil, prStatus: nil, prNumber: nil, diffSummaryTotalFiles: nil, taskStatsTotal: nil, taskStatsCompleted: nil, taskStatsInProgress: nil, agentSummaryCount: nil, agentSummaryAgents: nil)
        let ws2 = Workspace(id: "2", title: "Test", branch: nil, baseRef: nil, status: nil, activity: nil, displayStatus: nil, lastActivity: nil, updatedAt: nil, repositoryOwner: nil, repositoryName: nil, prStatus: nil, prNumber: nil, diffSummaryTotalFiles: nil, taskStatsTotal: nil, taskStatsCompleted: nil, taskStatsInProgress: nil, agentSummaryCount: nil, agentSummaryAgents: nil)
        #expect(ws1 != ws2)
    }

    // MARK: - Workspace.pullRequests (PROTOCOL §5.1 / §7.6)

    @Test func workspaceDecodesPullRequests() async throws {
        let json = """
        {
            "id": "ws-1",
            "title": "Test",
            "pullRequests": [
                {
                    "id": "pr-1",
                    "number": 42,
                    "title": "feat: add thing",
                    "url": "https://github.com/acme/app/pull/42",
                    "status": "Open",
                    "createdAt": "2026-08-01T10:00:00Z",
                    "updatedAt": "2026-08-02T10:00:00Z"
                },
                {
                    "number": 43,
                    "status": "Merged"
                }
            ]
        }
        """.data(using: .utf8)!
        let ws = try JSONDecoder().decode(Workspace.self, from: json)
        let prs = try #require(ws.pullRequests)
        #expect(prs.count == 2)
        #expect(prs[0].number == 42)
        #expect(prs[0].title == "feat: add thing")
        #expect(prs[0].url == "https://github.com/acme/app/pull/42")
        #expect(prs[0].status == "Open")
        #expect(prs[0].createdAt == "2026-08-01T10:00:00Z")
        #expect(prs[0].updatedAt == "2026-08-02T10:00:00Z")
        #expect(prs[1].number == 43)
        #expect(prs[1].status == "Merged")
        #expect(prs[1].title == nil)
        #expect(prs[1].url == nil)
    }

    @Test func workspaceDecodesAbsentPullRequestsAsNil() async throws {
        let json = """
        {"id": "ws-1", "title": "Test"}
        """.data(using: .utf8)!
        let ws = try JSONDecoder().decode(Workspace.self, from: json)
        #expect(ws.pullRequests == nil)
    }

    @Test func workspacePullRequestKeepsUnknownStatusRaw() async throws {
        // Future status variants pass through as raw strings (lenient).
        let json = """
        {"id": "ws-1", "title": "Test", "pullRequests": [{"number": 7, "status": "SomeFutureStatus"}]}
        """.data(using: .utf8)!
        let ws = try JSONDecoder().decode(Workspace.self, from: json)
        #expect(ws.pullRequests?.count == 1)
        #expect(ws.pullRequests?.first?.status == "SomeFutureStatus")
    }

    // MARK: - Workspace.activePullRequest (PROTOCOL §5.1 / §7.6)

    @Test func workspaceDecodesActivePullRequest() async throws {
        let json = """
        {
            "id": "ws-1",
            "title": "Test",
            "activePullRequest": {
                "id": "pr-1",
                "number": 42,
                "title": "feat: add thing",
                "url": "https://github.com/acme/app/pull/42",
                "status": "Open",
                "createdAt": "2026-08-01T10:00:00Z",
                "updatedAt": "2026-08-02T10:00:00Z"
            }
        }
        """.data(using: .utf8)!
        let ws = try JSONDecoder().decode(Workspace.self, from: json)
        let pr = try #require(ws.activePullRequest)
        #expect(pr.number == 42)
        #expect(pr.status == "Open")
        #expect(pr.title == "feat: add thing")
        #expect(pr.url == "https://github.com/acme/app/pull/42")
        #expect(pr.createdAt == "2026-08-01T10:00:00Z")
        #expect(pr.updatedAt == "2026-08-02T10:00:00Z")
    }

    @Test func workspaceDecodesAbsentActivePullRequestAsNil() async throws {
        let json = """
        {"id": "ws-1", "title": "Test"}
        """.data(using: .utf8)!
        let ws = try JSONDecoder().decode(Workspace.self, from: json)
        #expect(ws.activePullRequest == nil)
    }

    // MARK: - SpecialistInfo wire decoding (specialist.list)

    @Test func specialistInfoWireDecodesResolvedFields() async throws {
        // Fixture mirroring a daemon specialist.list entry carrying the
        // additive resolvedModel/resolvedProvider preview fields (PROTOCOL §5.11).
        let info = SpecialistInfo(wire: [
            "id": "implementor",
            "name": "Implementor",
            "description": "Implements tasks",
            "prompt": "You are an implementor.",
            "resolvedModel": "sonnet4.5",
            "resolvedProvider": "auggie",
        ])
        let specialist = try #require(info)
        #expect(specialist.id == "implementor")
        #expect(specialist.resolvedModel == "sonnet4.5")
        #expect(specialist.resolvedProvider == "auggie")
        #expect(specialist.hidden == false)
    }

    @Test func specialistInfoWireDecodesOmittedResolvedFields() async throws {
        // Both fields are omitted when resolution yields the provider CLI
        // default — clients render "Provider default".
        let info = SpecialistInfo(wire: [
            "id": "implementor",
            "name": "Implementor",
            "description": "Implements tasks",
            "modelTier": "balanced",
        ])
        let specialist = try #require(info)
        #expect(specialist.resolvedModel == nil)
        #expect(specialist.resolvedProvider == nil)
        #expect(specialist.hidden == false)
    }

    @Test func specialistInfoWireDecodesHiddenTrue() async throws {
        let info = SpecialistInfo(wire: [
            "id": "chief-of-staff",
            "name": "Chief of Staff",
            "description": "Chief workspace specialist",
            "hidden": true,
        ])
        let specialist = try #require(info)
        #expect(specialist.hidden == true)
    }

    @Test func specialistInfoWireDecodesHiddenFalse() async throws {
        let info = SpecialistInfo(wire: [
            "id": "verifier",
            "name": "Verifier",
            "description": "Verifies work",
            "hidden": false,
        ])
        let specialist = try #require(info)
        #expect(specialist.hidden == false)
    }

    @Test func specialistInfoWireRejectsMissingRequiredFields() async throws {
        #expect(SpecialistInfo(wire: ["id": "x", "name": "X"]) == nil)
    }

    @Test func pickableDropsHiddenSpecialists() async throws {
        let specialists = [
            SpecialistInfo(id: "spec-writer", name: "Coordinator", description: "Plans"),
            SpecialistInfo(id: "chief-of-staff", name: "Chief of Staff", description: "Chief", hidden: true),
            SpecialistInfo(id: "implementor", name: "Implementor", description: "Implements", hidden: false),
        ]
        #expect(specialists.pickable.map(\.id) == ["spec-writer", "implementor"])
    }

    @Test func pickableKeepsAllWhenNoneHidden() async throws {
        let specialists = [
            SpecialistInfo(id: "spec-writer", name: "Coordinator", description: "Plans"),
            SpecialistInfo(id: "implementor", name: "Implementor", description: "Implements"),
        ]
        #expect(specialists.pickable.map(\.id) == ["spec-writer", "implementor"])
    }

    // MARK: - TaskDisplayStatus (PROTOCOL §5.4 task-status vocabulary)

    @Test func taskDisplayStatusParsesFullVocabulary() {
        #expect(TaskDisplayStatus(wire: "not_started") == .notStarted)
        #expect(TaskDisplayStatus(wire: "waiting") == .waiting)
        #expect(TaskDisplayStatus(wire: "discussion_needed") == .discussionNeeded)
        #expect(TaskDisplayStatus(wire: "blocked") == .blocked)
        #expect(TaskDisplayStatus(wire: "in_progress") == .inProgress)
        #expect(TaskDisplayStatus(wire: "review_required") == .reviewRequired)
        #expect(TaskDisplayStatus(wire: "complete") == .complete)
        #expect(TaskDisplayStatus(wire: "cancelled") == .cancelled)
    }

    @Test func taskDisplayStatusNormalizesLegacyCheckboxWords() {
        #expect(TaskDisplayStatus(wire: "todo") == .notStarted)
        #expect(TaskDisplayStatus(wire: "in-progress") == .inProgress)
        #expect(TaskDisplayStatus(wire: "done") == .complete)
    }

    @Test func taskDisplayStatusUnknownFallback() {
        #expect(TaskDisplayStatus(wire: "some_future_status") == .unknown)
        #expect(TaskDisplayStatus(wire: "") == .unknown)
    }

    @Test func blockedIsDistinctFromUnknown() {
        let blocked = TaskDisplayStatus(wire: "blocked")
        let unknown = TaskDisplayStatus(wire: "mystery")
        #expect(blocked != unknown)
        #expect(blocked.emoji != unknown.emoji)
        #expect(blocked.label == "Blocked")
        #expect(blocked.needsAttention == true)
        #expect(unknown.needsAttention == false)
    }

    @Test func discussionNeededNeedsAttention() {
        let status = TaskDisplayStatus(wire: "discussion_needed")
        #expect(status == .discussionNeeded)
        #expect(status.needsAttention == true)
        #expect(status.emoji != TaskDisplayStatus.unknown.emoji)
    }

    @Test func nonAttentionStatusesDoNotNeedAttention() {
        for wire in ["not_started", "waiting", "in_progress", "review_required", "complete", "cancelled"] {
            #expect(TaskDisplayStatus(wire: wire).needsAttention == false)
        }
    }

    @Test func workspaceTaskExposesBlockedDisplayStatus() {
        let task = WorkspaceTask.parseTask([
            "id": "task-1",
            "title": "Broken sandbox",
            "status": "blocked",
            "updatedAt": "2026-07-30T10:00:00Z"
        ])
        #expect(task?.status == "blocked")
        #expect(task?.displayStatus == .blocked)
        #expect(task?.displayStatus.needsAttention == true)
    }

    @Test func noteExposesTaskDisplayStatus() {
        let blockedNote = Note.parseNote([
            "id": "note-1",
            "title": "Task note",
            "metadata": ["task": ["status": "blocked"] as [String: Any]] as [String: Any]
        ])
        #expect(blockedNote?.taskStatus == "blocked")
        #expect(blockedNote?.taskDisplayStatus == .blocked)

        let plainNote = Note.parseNote(["id": "note-2", "title": "Plain"])
        #expect(plainNote?.taskStatus == nil)
        #expect(plainNote?.taskDisplayStatus == nil)
    }

    @Test func noteParsesExtendedTaskMetadata() {
        let note = Note.parseNote([
            "id": "t1",
            "title": "Task",
            "metadata": ["task": [
                "status": "in_progress",
                "assignedAgentIds": ["agent-1", "agent-2"],
                "dependsOn": ["dep-a", "dep-b"],
                "conflictsWith": ["conf-c"],
                "unmetDependsOn": ["dep-b"],
                "estimatedEffort": "2h",
            ] as [String: Any]] as [String: Any]
        ])
        #expect(note?.taskStatus == "in_progress")
        #expect(note?.assignedAgentIds == ["agent-1", "agent-2"])
        #expect(note?.dependsOn == ["dep-a", "dep-b"])
        #expect(note?.conflictsWith == ["conf-c"])
        #expect(note?.unmetDependsOn == ["dep-b"])
        #expect(note?.estimatedEffort == "2h")
    }

    @Test func noteTaskMetadataDefaultsWhenOmitted() {
        // Task metadata with only status: the omitted-when-empty fields
        // default to empty/nil (PROTOCOL §5.2).
        let taskNote = Note.parseNote([
            "id": "t1",
            "title": "Task",
            "metadata": ["task": ["status": "not_started"] as [String: Any]] as [String: Any]
        ])
        #expect(taskNote?.assignedAgentIds == [])
        #expect(taskNote?.dependsOn == [])
        #expect(taskNote?.conflictsWith == [])
        #expect(taskNote?.unmetDependsOn == [])
        #expect(taskNote?.estimatedEffort == nil)

        // Non-task note: same defaults.
        let plainNote = Note.parseNote(["id": "note-2", "title": "Plain"])
        #expect(plainNote?.assignedAgentIds == [])
        #expect(plainNote?.dependsOn == [])
        #expect(plainNote?.conflictsWith == [])
        #expect(plainNote?.unmetDependsOn == [])
        #expect(plainNote?.estimatedEffort == nil)
    }

    @Test func noteCopiesPreserveTaskMetadata() {
        let note = Note.parseNote([
            "id": "t1",
            "title": "Task",
            "metadata": ["task": [
                "status": "in_progress",
                "assignedAgentIds": ["agent-1"],
                "dependsOn": ["dep-a"],
                "conflictsWith": ["conf-c"],
                "unmetDependsOn": ["dep-a"],
                "estimatedEffort": "30m",
            ] as [String: Any]] as [String: Any]
        ])

        let edited = note?.withContent("new content")
        #expect(edited?.content == "new content")
        #expect(edited?.assignedAgentIds == ["agent-1"])
        #expect(edited?.dependsOn == ["dep-a"])
        #expect(edited?.conflictsWith == ["conf-c"])
        #expect(edited?.unmetDependsOn == ["dep-a"])
        #expect(edited?.estimatedEffort == "30m")

        let restatused = note?.withTaskStatus("complete")
        #expect(restatused?.taskStatus == "complete")
        #expect(restatused?.assignedAgentIds == ["agent-1"])
        #expect(restatused?.dependsOn == ["dep-a"])
        #expect(restatused?.conflictsWith == ["conf-c"])
        #expect(restatused?.unmetDependsOn == ["dep-a"])
        #expect(restatused?.estimatedEffort == "30m")
    }
}

