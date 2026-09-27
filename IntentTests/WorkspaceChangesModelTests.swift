import Foundation
@testable import Intent
import Testing

enum WorkspaceChangesFixture {
    static func change(id: String = "change-1", path: String = "src/main.swift", stage: String = "unstaged") -> [String: Any] {
        [
            "id": id,
            "file": "/worktree/\(path)",
            "relativePath": path,
            "stage": stage,
            "status": "modified",
            "stats": ["additions": 12, "deletions": 3, "binary": false],
            "attribution": ["agent": ["agentId": "agent-1", "agentName": "Implementor"]]
        ]
    }

    static func commit(_ hash: String = "commit-1") -> [String: Any] {
        [
            "hash": hash,
            "message": "Add changes\n\nKeep the full message.",
            "author": "Sam",
            "date": "2026-09-27T20:00:00Z",
            "agentId": "agent-1",
            "isPushed": false
        ]
    }

    static func snapshot(_ changes: [[String: Any]] = [], truncated: Bool = false) -> [String: Any] {
        ["changes": changes, "truncated": truncated, "totalCount": changes.count]
    }

    static func page(
        _ hashes: [String] = [],
        nextToken: String? = nil,
        boundary: String? = "workspace-base"
    ) -> [String: Any] {
        [
            "commits": hashes.map { commit($0) },
            "nextToken": nextToken as Any? ?? NSNull(),
            "boundarySha": boundary as Any? ?? NSNull()
        ]
    }
}

struct WorkspaceChangesModelTests {
    @Test func trackedFilePreservesPathStageBinaryStatsAndAttribution() throws {
        var wire = WorkspaceChangesFixture.change(stage: "staged")
        wire["status"] = "renamed"
        wire["stats"] = ["additions": 0, "deletions": 0, "binary": true]
        let change = try #require(WorkspaceChange.parse(wire))
        #expect(change.path == "src/main.swift")
        #expect(change.stage == "staged")
        #expect(change.status == "renamed")
        #expect(change.isBinary)
        #expect(change.additions == 0)
        #expect(change.deletions == 0)
        #expect(change.agentName == "Implementor")
    }

    @Test func absentOptionalAttributionAndStatusAreSupported() throws {
        var wire = WorkspaceChangesFixture.change()
        wire.removeValue(forKey: "attribution")
        wire.removeValue(forKey: "status")
        wire["stats"] = ["additions": 12, "deletions": 3]
        let change = try #require(WorkspaceChange.parse(wire))
        #expect(change.agentName == nil)
        #expect(change.status == "modified")
        #expect(change.isBinary == false)
    }

    @Test func malformedFilesDoNotBecomeAnEmptySuccessfulSnapshot() {
        for field in ["id", "relativePath", "stage", "stats"] {
            var wire = WorkspaceChangesFixture.change()
            wire.removeValue(forKey: field)
            #expect(throws: WorkspaceChangesDecodingError.self) {
                try WorkspaceChangesSnapshot(WorkspaceChangesFixture.snapshot([wire]))
            }
        }
        #expect(WorkspaceChange.parse(WorkspaceChangesFixture.change(stage: "unexpected")) == nil)
        var negativeStats = WorkspaceChangesFixture.change()
        negativeStats["stats"] = ["additions": -1, "deletions": 0]
        #expect(WorkspaceChange.parse(negativeStats) == nil)
        #expect(throws: WorkspaceChangesDecodingError.self) {
            try WorkspaceChangesSnapshot(["changes": "invalid", "truncated": false])
        }
    }

    @Test func metadataOnlyCommitPreservesIdentityAndProvenance() throws {
        let commit = try #require(WorkspaceCommit.parse(WorkspaceChangesFixture.commit()))
        #expect(commit.id == commit.hash)
        #expect(commit.message == "Add changes\n\nKeep the full message.")
        #expect(commit.author == "Sam")
        #expect(commit.date == "2026-09-27T20:00:00Z")
        #expect(commit.agentId == "agent-1")
        #expect(commit.isPushed == false)
    }

    @Test func nullBoundaryAndTokenPreserveFailClosedEmptyHistory() throws {
        let page = try WorkspaceCommitPage(WorkspaceChangesFixture.page(boundary: nil))
        #expect(page.commits.isEmpty)
        #expect(page.boundarySha == nil)
        #expect(page.nextToken == nil)
    }

    @Test func malformedCommitAndPaginationAreRejected() {
        var missingHash = WorkspaceChangesFixture.commit()
        missingHash.removeValue(forKey: "hash")
        #expect(WorkspaceCommit.parse(missingHash) == nil)
        var page = WorkspaceChangesFixture.page(["first"])
        page["nextToken"] = 42
        #expect(throws: WorkspaceChangesDecodingError.self) { try WorkspaceCommitPage(page) }
        page["nextToken"] = NSNull()
        page["commits"] = [missingHash]
        #expect(throws: WorkspaceChangesDecodingError.self) { try WorkspaceCommitPage(page) }
    }
}
