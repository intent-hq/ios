import Foundation

@MainActor
struct WorkspaceDiffLoader {
    let connectionManager: ConnectionManagerRouting
    let workspaceId: String
    var gitRootId: String?

    func workingFile(path: String, staged: Bool) async throws -> [WorkspaceDiffHunk] {
        let response = try await connectionManager.request("git.diffs", params: scoped([
            "path": path, "staged": staged
        ]))
        try Task.checkCancellation()
        let files: [WorkspaceFileDiff] = try decode(response)
        return files.first { $0.path == path }?.hunks ?? []
    }

    func commitFiles(hash: String) async throws -> [WorkspaceCommitFile] {
        struct Details: Decodable { let fileDetails: [WorkspaceCommitFile] }
        let response = try await connectionManager.request("git.commitDetails", params: scoped(["commitHash": hash]))
        try Task.checkCancellation()
        let details: Details = try decode(response)
        return details.fileDetails
    }

    func commitFile(path: String, hash: String) async throws -> [WorkspaceDiffHunk] {
        let contents = try await commitContents(path: path, hash: hash)
        try Task.checkCancellation()
        let hunks = try await Task.detached(priority: .userInitiated) {
            try WorkspaceDiffBuilder.hunks(old: contents.old, new: contents.new)
        }.value
        try Task.checkCancellation()
        return hunks
    }

    private func commitContents(path: String, hash: String) async throws -> (old: String, new: String) {
        if gitRootId != nil {
            return try await secondaryCommitContents(path: path, hash: hash)
        }
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
        if let file = files.first(where: { $0.file == path }) {
            return (file.oldContent, file.newContent)
        }
        // A root commit has no parent; its files are additions against the empty tree.
        return ("", try await content(path: path, ref: hash))
    }

    private func secondaryCommitContents(path: String, hash: String) async throws -> (old: String, new: String) {
        struct Parent: Decodable { let date: String }
        let response = try await connectionManager.request("git.commitDetails", params: scoped(["commitHash": "\(hash)^"]))
        try Task.checkCancellation()
        let parent: Parent = try decode(response)
        let old = parent.date.isEmpty ? "" : try await content(path: path, ref: "\(hash)^")
        let new = try await content(path: path, ref: hash)
        return (old, new)
    }

    private func content(path: String, ref: String) async throws -> String {
        struct Content: Decodable { let content: String }
        let response = try await connectionManager.request("git.showFile", params: scoped(["filePath": path, "ref": ref]))
        try Task.checkCancellation()
        let file: Content = try decode(response)
        return file.content
    }

    private func scoped(_ values: [String: Any]) -> [String: Any] {
        var params = values
        params["workspaceId"] = workspaceId
        if let gitRootId { params["gitRootId"] = gitRootId }
        return params
    }

    private func decode<Value: Decodable>(_ response: Any) throws -> Value {
        try JSONDecoder().decode(Value.self, from: JSONSerialization.data(withJSONObject: response))
    }
}
