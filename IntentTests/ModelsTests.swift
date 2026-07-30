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

    // MARK: - SpecialistInfo wire decoding (specialist.list)

    @Test func specialistInfoWireDecodesWithoutHidden() async throws {
        let info = SpecialistInfo(wire: [
            "id": "implementor",
            "name": "Implementor",
            "description": "Implements tasks",
            "modelTier": "balanced",
        ])
        let specialist = try #require(info)
        #expect(specialist.id == "implementor")
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
            SpecialistInfo(id: "spec-writer", name: "Coordinator", description: "Plans", modelTier: nil, model: nil),
            SpecialistInfo(id: "chief-of-staff", name: "Chief of Staff", description: "Chief", modelTier: nil, model: nil, hidden: true),
            SpecialistInfo(id: "implementor", name: "Implementor", description: "Implements", modelTier: nil, model: nil, hidden: false),
        ]
        #expect(specialists.pickable.map(\.id) == ["spec-writer", "implementor"])
    }

    @Test func pickableKeepsAllWhenNoneHidden() async throws {
        let specialists = [
            SpecialistInfo(id: "spec-writer", name: "Coordinator", description: "Plans", modelTier: nil, model: nil),
            SpecialistInfo(id: "implementor", name: "Implementor", description: "Implements", modelTier: nil, model: nil),
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
}

