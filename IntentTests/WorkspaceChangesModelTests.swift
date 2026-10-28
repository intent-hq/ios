import Foundation
@testable import Intent
import Testing

enum WorkspaceChangesFixture {
    private static let additions = 12
    private static let deletions = 3

    static func change(id: String = "change-1", path: String = "src/main.swift", stage: String = "unstaged") -> [String: Any] {
        [
            "id": id,
            "file": "/worktree/\(path)",
            "relativePath": path,
            "stage": stage,
            "status": "modified",
            "stats": ["additions": additions, "deletions": deletions, "binary": false],
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
    @Test func gitStatusOnlyEnrichesMatchingPathAndStage() throws {
        var staged = WorkspaceChangesFixture.change(id: "staged", stage: "staged")
        staged["stats"] = ["additions": 0, "deletions": 0, "binary": true]
        let tracked = try WorkspaceChangesSnapshot(WorkspaceChangesFixture.snapshot([
            WorkspaceChangesFixture.change(id: "unstaged", stage: "unstaged"),
            staged,
            WorkspaceChangesFixture.change(path: "removed.swift")
        ]))
        let snapshot = try WorkspaceChangesSnapshot(
            [
                "files": [
                    ["path": "src/main.swift", "status": "D", "staged": true],
                    ["path": "src/main.swift", "status": "M", "staged": false],
                    ["path": "manual.swift", "status": "?", "staged": false]
                ]
            ],
            rootId: "primary",
            trackedChanges: tracked.changes
        )
        #expect(snapshot.changes.map(\.stage) == ["staged", "unstaged", "unstaged"])
        #expect(snapshot.changes.map(\.status) == ["deleted", "modified", "untracked"])
        #expect(snapshot.changes[0].id != snapshot.changes[1].id)
        #expect(snapshot.changes[0].additions == tracked.changes[1].additions)
        #expect(snapshot.changes[0].isBinary)
        #expect(snapshot.changes[1].additions == tracked.changes[0].additions)
        #expect(snapshot.changes[1].isBinary == false)
        #expect(snapshot.changes[1].agentName == "Implementor")
        #expect(snapshot.changes[0].hasLineStats)
        #expect(snapshot.changes[2].hasLineStats == false)
        #expect(snapshot.changes[2].agentName == nil)
        #expect(snapshot.changes.map(\.path).contains("removed.swift") == false)
    }

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
