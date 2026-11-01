import Foundation

/// A changed file placed in a `ChangeTree` by its slash-separated path.
protocol ChangeTreeFile: Equatable {
    var id: String { get }
    var path: String { get }
}

extension WorkspaceChange: @MainActor ChangeTreeFile {}

typealias WorkspaceChangeTree = ChangeTree<WorkspaceChange>

struct ChangeTree<File: ChangeTreeFile> {
    enum Node: Identifiable, Equatable {
        case directory(path: String, children: [Self])
        case file(File)

        var id: String {
            switch self {
            case .directory(let path, _): "directory:\(path)"
            case .file(let file): "file:\(file.id)"
            }
        }

        var path: String {
            switch self {
            case .directory(let path, _): path
            case .file(let file): file.path
            }
        }

        var name: String {
            path.components(separatedBy: "/").last ?? path
        }

        var fileCount: Int {
            switch self {
            case .directory(_, let children): children.reduce(0) { $0 + $1.fileCount }
            case .file: 1
            }
        }
    }

    struct TreeRow: Identifiable {
        let node: Node
        let depth: Int
        var id: String { node.id }
    }

    private struct Entry {
        let file: File
        let components: [String]
    }

    let roots: [Node]

    init(files: [File]) {
        roots = Self.build(files.map { Entry(file: $0, components: $0.path.components(separatedBy: "/")) }, depth: 0)
    }

    func visibleRows(collapsedPaths: Set<String>) -> [TreeRow] {
        var rows: [TreeRow] = []
        var pending = roots.reversed().map { TreeRow(node: $0, depth: 0) }
        while let row = pending.popLast() {
            rows.append(row)
            if case let .directory(path, children) = row.node, !collapsedPaths.contains(path) {
                pending.append(contentsOf: children.reversed().map { TreeRow(node: $0, depth: row.depth + 1) })
            }
        }
        return rows
    }

    private static func build(_ entries: [Entry], depth: Int) -> [Node] {
        var directories: [String: [Entry]] = [:]
        var files: [Node] = []
        for entry in entries {
            if entry.components.count > depth + 1 {
                let path = entry.components.prefix(depth + 1).joined(separator: "/")
                directories[path, default: []].append(entry)
            } else {
                files.append(.file(entry.file))
            }
        }
        let folders = directories.map { path, descendants in
            Node.directory(path: path, children: build(descendants, depth: depth + 1))
        }
        return folders.sorted(by: precedes) + files.sorted(by: precedes)
    }

    private static func precedes(_ lhs: Node, _ rhs: Node) -> Bool {
        let order = lhs.name.localizedStandardCompare(rhs.name)
        return order == .orderedSame ? lhs.id < rhs.id : order == .orderedAscending
    }
}
