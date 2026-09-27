import Foundation
@testable import Intent
import Testing

struct WorkspaceDiffTests {
    @Test func replacementPreservesContextAndLineNumbers() throws {
        let hunks = try WorkspaceDiffBuilder.hunks(old: "first\nold\nlast\n", new: "first\nnew\nlast\n")
        let hunk = try #require(hunks.first)
        #expect(hunks.count == 1)
        #expect(hunk.lines.map(\.type) == [.context, .deletion, .addition, .context])
        #expect(hunk.lines.map(\.oldNumber) == [1, 2, nil, 3])
        #expect(hunk.lines.map(\.newNumber) == [1, nil, 2, 3])
        #expect(hunk.oldLines == 3)
        #expect(hunk.newLines == 3)
    }

    @Test func addedAndDeletedFilesHaveOnlyOneSide() throws {
        let added = try WorkspaceDiffBuilder.hunks(old: "", new: "new\n")
        #expect(added.first?.oldStart == 0)
        #expect(added.first?.oldLines == 0)
        #expect(added.first?.lines.map(\.type) == [.addition])
        let deleted = try WorkspaceDiffBuilder.hunks(old: "gone\n", new: "")
        #expect(deleted.first?.newStart == 0)
        #expect(deleted.first?.newLines == 0)
        #expect(deleted.first?.lines.map(\.type) == [.deletion])
    }

    @Test func unchangedAndEmptyFilesProduceNoHunks() throws {
        #expect(try WorkspaceDiffBuilder.hunks(old: "unchanged\n", new: "unchanged\n").isEmpty)
        #expect(try WorkspaceDiffBuilder.hunks(old: "", new: "").isEmpty)
    }

    @Test func separatesDistantEditsAndOmitsUnchangedMiddle() throws {
        let middle = (1...20).map { "context \($0)" }.joined(separator: "\n")
        let hunks = try WorkspaceDiffBuilder.hunks(old: "old\n\(middle)\nend\n", new: "new\n\(middle)\nfinish\n")
        #expect(hunks.count == 2)
        #expect(!hunks.flatMap(\.lines).contains { $0.content == "context 10" })
        #expect(hunks.last?.lines.last?.newNumber == 22)
    }

    @Test func newlineOnlyChangeIsVisible() throws {
        let hunks = try WorkspaceDiffBuilder.hunks(old: "text", new: "text\n")
        #expect(hunks.first?.lines.map(\.type) == [.deletion, .addition])
        #expect(hunks.first?.lines.first?.content.contains("No newline") == true)
    }

    @Test func rejectsBinaryAndExcessiveWork() {
        #expect(throws: WorkspaceDiffBuilder.Unavailable.self) {
            try WorkspaceDiffBuilder.hunks(old: "", new: "binary\0data")
        }
        let large = String(repeating: "line\n", count: 3000)
        #expect(throws: WorkspaceDiffBuilder.Unavailable.self) {
            try WorkspaceDiffBuilder.hunks(old: large, new: large + "extra\n")
        }
    }

    @Test func handlesRepeatedLinesAndReordering() throws {
        let hunks = try WorkspaceDiffBuilder.hunks(old: "same\none\nsame\ntwo\n", new: "two\nsame\none\nsame\n")
        let lines = hunks.flatMap(\.lines)
        #expect(lines.filter { $0.type != .addition }.map(\.content) == ["same", "one", "same", "two"])
        #expect(lines.filter { $0.type != .deletion }.map(\.content) == ["two", "same", "one", "same"])
    }
}

@MainActor
struct WorkspaceDiffLoaderTests {
    @Test func workingDiffUsesSelectedPathAndStage() async throws {
        let connection = FakeConnectionManager()
        connection.responseMap["git.diffs"] = [["path": "src/a.swift", "hunks": [[
            "oldStart": 1, "oldLines": 0, "newStart": 1, "newLines": 1,
            "lines": [["type": "Addition", "content": "added\n", "newNumber": 1]]
        ]]]]
        let loader = WorkspaceDiffLoader(connectionManager: connection, workspaceId: "workspace")
        let hunks = try await loader.workingFile(path: "src/a.swift", staged: true)
        #expect(hunks.first?.lines.first?.content == "added\n")
        #expect(hunks.first?.lines.first?.oldNumber == nil)
        let request = try #require(connection.requestLog.first)
        #expect(request.params["workspaceId"] as? String == "workspace")
        #expect(request.params["path"] as? String == "src/a.swift")
        #expect(request.params["staged"] as? Bool == true)
        _ = try await loader.workingFile(path: "src/a.swift", staged: false)
        #expect(connection.requestLog.last?.params["staged"] as? Bool == false)
    }

    @Test func commitDiffUsesFirstParentAndScopesThePath() async throws {
        let connection = FakeConnectionManager()
        connection.responseMap["git.branchDiff"] = [[
            "file": "file.swift", "oldContent": "before\n", "newContent": "after\n"
        ]]
        let loader = WorkspaceDiffLoader(connectionManager: connection, workspaceId: "workspace")
        let hunks = try await loader.commitFile(path: "file.swift", hash: "commit")
        #expect(hunks.first?.lines.map(\.content) == ["before", "after"])
        let request = try #require(connection.requestLog.first)
        #expect(request.params["baseRef"] as? String == "commit^")
        #expect(request.params["targetRef"] as? String == "commit")
        #expect(request.params["paths"] as? [String] == ["file.swift"])
        #expect(!connection.requestLog.contains { $0.method == "git.showFile" })
    }

    @Test func rootCommitLoadsItsContentAsAdditions() async throws {
        let connection = FakeConnectionManager()
        connection.responseMap["git.branchDiff"] = [] as [[String: Any]]
        connection.responseMap["git.showFile"] = ["content": "initial\n"]
        let loader = WorkspaceDiffLoader(connectionManager: connection, workspaceId: "workspace")
        let hunks = try await loader.commitFile(path: "README", hash: "root")
        #expect(hunks.first?.lines.map(\.type) == [.addition])
        #expect(connection.requestLog.last?.params["ref"] as? String == "root")
        #expect(connection.requestLog.last?.params["filePath"] as? String == "README")
    }

    @Test func commitMetadataLoadsFilesAndStatsOnDemand() async throws {
        let connection = FakeConnectionManager()
        connection.responseMap["git.commitDetails"] = ["fileDetails": [
            ["path": "file.swift", "additions": 2, "deletions": 1]
        ]]
        let loader = WorkspaceDiffLoader(connectionManager: connection, workspaceId: "workspace")
        let files = try await loader.commitFiles(hash: "commit")
        #expect(files.first?.path == "file.swift")
        #expect(files.first?.additions == 2)
        #expect(connection.requestLog.first?.params["commitHash"] as? String == "commit")
    }

    @Test func malformedDiffIsAnErrorInsteadOfAnEmptyState() async {
        let connection = FakeConnectionManager()
        connection.responseMap["git.diffs"] = ["unexpected": true]
        let loader = WorkspaceDiffLoader(connectionManager: connection, workspaceId: "workspace")
        await #expect(throws: (any Error).self) {
            try await loader.workingFile(path: "file.swift", staged: false)
        }
    }
}
