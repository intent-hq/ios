import Foundation
@testable import Intent
import Testing

@MainActor
struct WorkspaceFileEntryTests {
    @Test func bareListingsUseRelativePathsAndNaturalFolderFirstOrder() throws {
        let entries = try WorkspaceFileEntry.parseList([
            ["name": "file10.swift", "type": "file"],
            ["name": "folder10", "type": "directory"],
            ["name": "file2.swift", "type": "file"],
            ["name": "folder2", "type": "directory"]
        ])
        #expect(entries.map(\.name) == ["folder2", "folder10", "file2.swift", "file10.swift"])
        #expect(entries.map(\.path) == entries.map(\.name))
        #expect(entries.map(\.id) == entries.map(\.path))
        #expect(entries.map(\.isDirectory) == [true, true, false, false])
    }

    @Test func nestedPathsPreserveSpacesUnicodeAndLinkCharacters() throws {
        let name = " Résumé #1?%.txt "
        let entries = try WorkspaceFileEntry.parseList([["name": name, "type": "file"]], directoryPath: "docs/reports")
        #expect(entries.first?.name == name)
        #expect(entries.first?.path == "docs/reports/\(name)")
        #expect(try WorkspaceFileEntry.parseList([] as [[String: Any]]).isEmpty)
    }

    @Test(arguments: ["", ".", "..", "../outside", "folder/file", "/absolute", "nul\0byte"])
    func rejectsInvalidChildNames(_ name: String) {
        #expect(throws: WorkspaceFilesError.self) {
            try WorkspaceFileEntry.parseList([["name": name, "type": "file"]])
        }
    }

    @Test(arguments: ["", "/", "/absolute", "../outside", "folder/../outside", "folder//child", "folder/", "./folder"])
    func rejectsInvalidDirectoryPaths(_ path: String) {
        #expect(throws: WorkspaceFilesError.self) {
            try WorkspaceFileEntry.parseList([["name": "file", "type": "file"]], directoryPath: path)
        }
    }

    @Test func malformedOrDuplicateEntriesFailTheWholeListing() {
        let invalid: [Any] = [
            ["entries": [] as [[String: Any]]],
            [["name": "file"]],
            [["type": "file"]],
            [["name": "file", "type": "symlink"]],
            [["name": "file", "type": true] as [String: Any]],
            [["name": "file", "type": "file"], ["name": "file", "type": "directory"]],
            [["name": "valid", "type": "file"], ["name": 1, "type": "file"] as [String: Any]]
        ]
        for response in invalid {
            #expect(throws: WorkspaceFilesError.self) { try WorkspaceFileEntry.parseList(response) }
        }
    }
}
