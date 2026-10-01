import Foundation
@testable import Intent
import Testing

struct WorkspaceChangeTreeTests {
    @Test func emptyChangesHaveNoFoldersOrRows() {
        let tree = WorkspaceChangeTree(files: [])
        #expect(tree.roots.isEmpty)
        #expect(tree.visibleRows(collapsedPaths: []).isEmpty)
    }

    @Test func groupsDirectoriesBeforeFilesAndSortsNamesNaturally() {
        let files = ["z.txt", "src/file10.swift", "src/nested/child.swift", "README.md", "src/file2.swift", "docs/guide.md"].map { file($0) }
        let tree = WorkspaceChangeTree(files: files)
        let rows = tree.visibleRows(collapsedPaths: [])
        #expect(rows.map(\.node.path) == [
            "docs", "docs/guide.md", "src", "src/nested", "src/nested/child.swift",
            "src/file2.swift", "src/file10.swift", "README.md", "z.txt"
        ])
        #expect(rows.map(\.depth) == [0, 1, 0, 1, 2, 1, 1, 0, 0])
        #expect(tree.roots.first?.fileCount == 1)
        #expect(tree.roots.first { $0.path == "src" }?.fileCount == files.filter { $0.path.hasPrefix("src/") }.count)
        #expect(WorkspaceChangeTree(files: Array(files.reversed())).roots == tree.roots)
    }

    @Test func fileLeavesKeepOriginalIdentityPathAndDiffMetadata() throws {
        var wire = WorkspaceChangesFixture.change(id: "staged-rename", path: "My Sources/新しい file.swift", stage: "staged")
        wire["status"] = "renamed"
        wire["stats"] = ["additions": 0, "deletions": 0, "binary": true]
        let change = try #require(WorkspaceChange.parse(wire))
        let rows = WorkspaceChangeTree(files: [change]).visibleRows(collapsedPaths: [])
        let leaf = try #require(rows.last)
        #expect(leaf.node == .file(change))
        #expect(leaf.node.name == "新しい file.swift")
        #expect(leaf.node.path == change.path)
        #expect(leaf.id == "file:staged-rename")
    }

    @Test func repeatedNamesAndFileDirectoryCollisionsStayDistinct() {
        let files = [file("src"), file("src/main.swift"), file("tests/main.swift"), file("src/main.swift", stage: "staged")]
        let rows = WorkspaceChangeTree(files: files).visibleRows(collapsedPaths: [])
        let leaves = rows.compactMap { row -> WorkspaceChange? in
            guard case .file(let file) = row.node else { return nil }
            return file
        }
        #expect(Set(rows.map(\.id)).count == rows.count)
        #expect(Set(leaves.map(\.id)) == Set(files.map(\.id)))
        #expect(rows.contains { $0.id == "directory:src" })
        #expect(rows.contains { $0.id == "file:unstaged:src" })
    }

    @Test func collapsingFolderHidesOnlyDescendantsAndRetainsNestedChoices() {
        let tree = WorkspaceChangeTree(files: [file("src/nested/child.swift"), file("src/main.swift"), file("src2/other.swift")])
        #expect(tree.visibleRows(collapsedPaths: ["src", "src/nested"]).map(\.node.path) == [
            "src", "src2", "src2/other.swift"
        ])
        #expect(tree.visibleRows(collapsedPaths: ["src/nested"]).map(\.node.path) == [
            "src", "src/nested", "src/main.swift", "src2", "src2/other.swift"
        ])
        #expect(tree.visibleRows(collapsedPaths: []).contains { $0.node.path == "src/nested/child.swift" })
    }

    @Test func folderIdentityAndCollapseSurviveRefreshedContents() throws {
        let before = WorkspaceChangeTree(files: [file("src/old.swift")])
        let after = WorkspaceChangeTree(files: [file("src/new.swift"), file("src/nested/added.swift")])
        let folder = try #require(before.roots.first)
        #expect(after.roots.first?.id == folder.id)
        #expect(after.visibleRows(collapsedPaths: [folder.path]).map(\.node.path) == ["src"])
        #expect(after.roots.first?.fileCount == 2)
    }

    private func file(_ path: String, stage: String = "unstaged") -> WorkspaceChange {
        WorkspaceChange(
            id: "\(stage):\(path)", path: path, stage: stage, status: "modified",
            additions: 1, deletions: 0, isBinary: false, agentName: nil
        )
    }
}
