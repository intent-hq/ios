import Foundation

@MainActor
struct WorkspaceDiffLoader {
    let connectionManager: ConnectionManagerRouting
    let workspaceId: String

    func workingFile(path: String, staged: Bool) async throws -> [WorkspaceDiffHunk] {
        let response = try await connectionManager.request("git.diffs", params: [
            "workspaceId": workspaceId, "path": path, "staged": staged
        ])
        try Task.checkCancellation()
        let files: [WorkspaceFileDiff] = try decode(response)
        return files.first { $0.path == path }?.hunks ?? []
    }

    func commitFiles(hash: String) async throws -> [WorkspaceCommitFile] {
        struct Details: Decodable { let fileDetails: [WorkspaceCommitFile] }
        let response = try await connectionManager.request("git.commitDetails", params: [
            "workspaceId": workspaceId, "commitHash": hash
        ])
        try Task.checkCancellation()
        let details: Details = try decode(response)
        return details.fileDetails
    }

    func commitFile(path: String, hash: String) async throws -> [WorkspaceDiffHunk] {
        struct Contents: Decodable {
            let file: String
            let oldContent: String
            let newContent: String
        }
        let response = try await connectionManager.request("git.branchDiff", params: [
            "workspaceId": workspaceId, "baseRef": "\(hash)^", "targetRef": hash, "paths": [path]
        ])
        try Task.checkCancellation()
        let files: [Contents] = try decode(response)
        let oldContent: String
        let newContent: String
        if let file = files.first(where: { $0.file == path }) {
            oldContent = file.oldContent
            newContent = file.newContent
        } else {
            // A root commit has no parent; its files are additions against the empty tree.
            struct Content: Decodable { let content: String }
            let response = try await connectionManager.request("git.showFile", params: [
                "workspaceId": workspaceId, "filePath": path, "ref": hash
            ])
            let file: Content = try decode(response)
            oldContent = ""
            newContent = file.content
        }
        try Task.checkCancellation()
        let hunks = try await Task.detached(priority: .userInitiated) {
            try WorkspaceDiffBuilder.hunks(old: oldContent, new: newContent)
        }.value
        try Task.checkCancellation()
        return hunks
    }

    private func decode<Value: Decodable>(_ response: Any) throws -> Value {
        try JSONDecoder().decode(Value.self, from: JSONSerialization.data(withJSONObject: response))
    }
}
