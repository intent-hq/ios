import Foundation
@testable import Intent
import Testing

extension WorkspaceDiffLoaderTests {
    @Test func secondaryWorkingDiffAndMetadataStayInSelectedRepository() async throws {
        let connection = FakeConnectionManager()
        connection.responseMap["git.diffs"] = [] as [[String: Any]]
        connection.responseMap["git.commitDetails"] = [
            "fileDetails": [["path": "file.swift", "additions": 2, "deletions": 1]]
        ]
        let loader = WorkspaceDiffLoader(connectionManager: connection, workspaceId: "workspace", gitRootId: "ios")
        _ = try await loader.workingFile(path: "file.swift", staged: true)
        let files = try await loader.commitFiles(hash: "commit")
        #expect(files.first?.path == "file.swift")
        #expect(connection.requestLog.map(\.method) == ["git.diffs", "git.commitDetails"])
        #expect(connection.requestLog.allSatisfy { $0.params["gitRootId"] as? String == "ios" })
        #expect(connection.requestLog.allSatisfy { $0.params["workspaceId"] as? String == "workspace" })
        #expect(connection.requestLog.first?.params["staged"] as? Bool == true)
        #expect(connection.requestLog.last?.params["commitHash"] as? String == "commit")
    }

    @Test func secondaryCommitDiffReadsBothVersionsFromSameRepository() async throws {
        let connection = FakeConnectionManager()
        connection.responseMap["git.commitDetails"] = ["date": "2026-09-27T10:00:00Z"]
        connection.responseQueueMap["git.showFile"] = [["content": "before\n"], ["content": "after\n"]]
        let loader = WorkspaceDiffLoader(connectionManager: connection, workspaceId: "workspace", gitRootId: "ios")
        let hunks = try await loader.commitFile(path: "file.swift", hash: "commit")
        #expect(hunks.first?.lines.map(\.content) == ["before", "after"])
        #expect(connection.requestLog.first?.params["commitHash"] as? String == "commit^")
        #expect(connection.requestLog.map(\.method) == ["git.commitDetails", "git.showFile", "git.showFile"])
        #expect(connection.requestLog.allSatisfy { $0.params["gitRootId"] as? String == "ios" })
        let contents = connection.requestLog.filter { $0.method == "git.showFile" }
        #expect(contents.map { $0.params["ref"] as? String } == ["commit^", "commit"])
        #expect(contents.allSatisfy { $0.params["filePath"] as? String == "file.swift" })
    }

    @Test func secondaryRootCommitUsesEmptyTreeWithoutReadingMissingParent() async throws {
        let connection = FakeConnectionManager()
        connection.responseMap["git.commitDetails"] = ["date": ""]
        connection.responseMap["git.showFile"] = ["content": "initial\n"]
        let loader = WorkspaceDiffLoader(connectionManager: connection, workspaceId: "workspace", gitRootId: "ios")
        let hunks = try await loader.commitFile(path: "README", hash: "initial")
        #expect(hunks.first?.lines.map(\.type) == [.addition])
        #expect(connection.requestLog.map(\.method) == ["git.commitDetails", "git.showFile"])
        #expect(connection.requestLog.last?.params["ref"] as? String == "initial")
        #expect(connection.requestLog.allSatisfy { $0.params["gitRootId"] as? String == "ios" })
    }

    @Test func secondaryCommitReadFailureDoesNotFallBackToMainRepository() async {
        let connection = FakeConnectionManager()
        connection.responseMap["git.commitDetails"] = ["date": "2026-09-27T10:00:00Z"]
        connection.errorMap["git.showFile"] = NSError(domain: "test", code: 1)
        let loader = WorkspaceDiffLoader(connectionManager: connection, workspaceId: "workspace", gitRootId: "ios")
        await #expect(throws: (any Error).self) {
            try await loader.commitFile(path: "file.swift", hash: "commit")
        }
        #expect(connection.requestLog.map(\.method) == ["git.commitDetails", "git.showFile"])
        #expect(connection.requestLog.allSatisfy { $0.params["gitRootId"] as? String == "ios" })
    }
}
