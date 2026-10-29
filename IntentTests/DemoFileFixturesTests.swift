import Foundation
@testable import Intent
import Testing

extension DemoFixturesTests {
    @Test func demoFileTreeOffersRichHighlightableExamples() async throws {
        let minimumLines = 25
        let maximumLines = 60
        var directories = ["."]
        var languages: Set<String> = []
        while let directory = directories.popLast() {
            let entries = try #require(DemoFixtures.response(for: "file.list", params: ["path": directory]) as? [[String: String]])
            for entry in entries {
                let name = try #require(entry["name"])
                let path = directory == "." ? name : "\(directory)/\(name)"
                if entry["type"] == "directory" {
                    directories.append(path)
                } else if let language = WorkspaceSyntaxHighlighter.language(forPath: path) {
                    let text = try demoFileText(path: path)
                    let count = text.components(separatedBy: "\n").count - 1
                    #expect((minimumLines...maximumLines).contains(count), "\(path): \(count) lines")
                    let tokens = try await WorkspaceSyntaxHighlighter.highlight(text: text, path: path)
                    #expect(!tokens.isEmpty, "No syntax tokens for \(path)")
                    languages.insert(language)
                }
            }
        }
        #expect(languages == ["swift", "python", "go", "rust", "json", "yaml", "ini", "markdown", "xml", "diff", "nginx", "javascript", "typescript", "css", "bash"])
    }

    @Test func demoChangesAndCommitFilesLoadConsistentMultiHunkDiffs() async throws {
        let response = try #require(DemoFixtures.response(for: "file-tracking.getChanges", params: [:]))
        let snapshot = try WorkspaceChangesSnapshot(response)
        let connection = FakeConnectionManager()
        connection.responseMap["git.commitDetails"] = DemoFixtures.response(for: "git.commitDetails", params: [:])
        let loader = WorkspaceDiffLoader(connectionManager: connection, workspaceId: "demo-ws-dashboard")
        let files = try await loader.commitFiles(hash: DemoChangesFixtures.commitHash)
        #expect(Set(files.map(\.path)) == Set(snapshot.changes.map(\.path)))
        var languages: Set<String> = []
        for change in snapshot.changes {
            let path = change.path
            connection.responseMap["git.diffs"] = DemoFixtures.response(for: "git.diffs", params: [
                "path": path, "staged": change.stage == "staged"
            ])
            connection.responseMap["git.branchDiff"] = DemoFixtures.response(for: "git.branchDiff", params: ["paths": [path]])
            let working = try await loader.workingFile(path: path, staged: change.stage == "staged")
            let committed = try await loader.commitFile(path: path, hash: DemoChangesFixtures.commitHash)
            #expect(working.count >= 2, "Expected separate edits in \(path)")
            #expect(working.flatMap(\.lines) == committed.flatMap(\.lines))
            let content = try demoFileText(path: path).components(separatedBy: "\n")
            for hunk in working {
                #expect(hunk.lines.contains { $0.type == .context })
                #expect(hunk.lines.contains { $0.type == .addition })
                #expect(hunk.lines.contains { $0.type == .deletion })
                for line in hunk.lines {
                    if let number = line.newNumber {
                        #expect(content.indices.contains(number - 1))
                        #expect(content[number - 1] == line.content)
                    }
                }
            }
            let metadata = try #require(files.first { $0.path == path })
            #expect(metadata.additions == working.flatMap(\.lines).filter { $0.type == .addition }.count)
            #expect(metadata.deletions == working.flatMap(\.lines).filter { $0.type == .deletion }.count)
            #expect(change.additions == metadata.additions)
            #expect(change.deletions == metadata.deletions)
            if path == "Sources/Analytics.swift" {
                #expect(working.flatMap(\.lines).contains { $0.type == .deletion && $0.content.hasPrefix("/*") })
            }
            languages.insert(try #require(WorkspaceSyntaxHighlighter.language(forPath: path)))
        }
        #expect(languages.isSuperset(of: ["swift", "python", "go", "json", "yaml", "typescript", "css", "bash"]))
    }

    private func demoFileText(path: String) throws -> String {
        let response = try #require(DemoFixtures.response(for: "file.readChunk", params: [
            "path": path, "offset": 0, "length": WorkspaceSyntaxHighlighter.maxBytes
        ]) as? [String: Any])
        let encoded = try #require(response["content"] as? String)
        let data = try #require(Data(base64Encoded: encoded))
        #expect(response["size"] as? Int == data.count)
        return try #require(String(data: data, encoding: .utf8))
    }
}
