import Foundation

/// A direct child returned by file.list, with a workspace-relative path for previews.
struct WorkspaceFileEntry: Identifiable, Equatable, Sendable {
    let path: String
    let name: String
    let isDirectory: Bool
    var id: String { path }

    static func parseList(_ result: Any, directoryPath: String = ".") throws -> [Self] {
        guard validDirectoryPath(directoryPath), let dictionaries = result as? [[String: Any]] else {
            throw WorkspaceFilesError.invalidListing
        }
        var names: Set<String> = []
        let entries = try dictionaries.map { dictionary -> Self in
            guard let name = dictionary["name"] as? String, validName(name),
                  let type = dictionary["type"] as? String, type == "file" || type == "directory",
                  names.insert(name).inserted else {
                throw WorkspaceFilesError.invalidListing
            }
            return Self(
                path: directoryPath == "." ? name : "\(directoryPath)/\(name)",
                name: name,
                isDirectory: type == "directory"
            )
        }
        return entries.sorted { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
            let order = lhs.name.localizedStandardCompare(rhs.name)
            return order == .orderedSame ? lhs.path < rhs.path : order == .orderedAscending
        }
    }

    private static func validName(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && !name.contains("/") && !name.contains("\0")
    }

    private static func validDirectoryPath(_ path: String) -> Bool {
        path == "." || path.components(separatedBy: "/").allSatisfy(validName)
    }
}

struct WorkspaceFileTreeRow: Identifiable, Equatable, Sendable {
    let entry: WorkspaceFileEntry
    let depth: Int
    var id: String { entry.id }
    var path: String { entry.path }
    var name: String { entry.name }
    var isDirectory: Bool { entry.isDirectory }
}

enum WorkspaceFilesError: LocalizedError {
    case invalidListing

    var errorDescription: String? {
        "The server returned an invalid file list. Try loading this folder again."
    }
}
