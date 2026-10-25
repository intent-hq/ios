import Foundation
import Observation

@MainActor
@Observable final class WorkspaceFilesStore {
    private(set) var workspaceId: String?
    private(set) var entriesByPath: [String: [WorkspaceFileEntry]] = [:]
    private(set) var expandedPaths: Set<String> = []
    private(set) var loadingPaths: Set<String> = []
    private(set) var errorsByPath: [String: String] = [:]
    var hasLoaded: Bool { entriesByPath["."] != nil }

    @ObservationIgnored private let connection: any ConnectionManagerRouting
    @ObservationIgnored private var revision = 0
    @ObservationIgnored private var requests: [String: UUID] = [:]

    init(connection: any ConnectionManagerRouting = ConnectionManager.shared) {
        self.connection = connection
    }

    /// Only loaded, expanded branches are flattened. Root children have depth zero.
    var rows: [WorkspaceFileTreeRow] {
        var result: [WorkspaceFileTreeRow] = []
        var pending = entriesByPath[".", default: []].reversed().map { WorkspaceFileTreeRow(entry: $0, depth: 0) }
        while let row = pending.popLast() {
            result.append(row)
            if row.isDirectory, expandedPaths.contains(row.path) {
                pending.append(contentsOf: entriesByPath[row.path, default: []].reversed().map { entry in
                    WorkspaceFileTreeRow(entry: entry, depth: row.depth + 1)
                })
            }
        }
        return result
    }

    /// Reentering the same workspace preserves expansion and cached listings.
    func start(workspaceId: String) async {
        guard !Task.isCancelled else { return }
        if self.workspaceId != workspaceId {
            reset()
            self.workspaceId = workspaceId
        }
        let currentRevision = revision
        await load(path: ".")
        await loadExpanded(force: false, revision: currentRevision)
    }

    func toggleDirectory(path: String) async {
        guard !Task.isCancelled, isDirectory(path) else { return }
        if expandedPaths.remove(path) != nil { return }
        expandedPaths.insert(path)
        let currentRevision = revision
        await load(path: path)
        await loadExpanded(force: false, revision: currentRevision)
    }

    func retry(path: String) async {
        guard !Task.isCancelled else { return }
        if path == "." {
            await refresh()
        } else if isDirectory(path) {
            let currentRevision = revision
            await load(path: path, force: true)
            await loadExpanded(force: false, revision: currentRevision)
        }
    }

    /// Reloads the root and visible expanded folders, retaining rows if a request fails.
    func refresh() async {
        guard !Task.isCancelled, workspaceId != nil else { return }
        invalidateRequests()
        let currentRevision = revision
        await load(path: ".", force: true)
        guard revision == currentRevision, errorsByPath["."] == nil else { return }
        await loadExpanded(force: true, revision: currentRevision)
    }

    /// Invalidates pending replies synchronously, including replies for a reused workspace ID.
    func reset() {
        invalidateRequests()
        workspaceId = nil
        entriesByPath = [:]
        expandedPaths = []
        errorsByPath = [:]
    }

    private func invalidateRequests() {
        revision &+= 1
        requests = [:]
        loadingPaths = []
    }

    private func load(path: String, force: Bool = false) async {
        guard !Task.isCancelled, let workspaceId,
              path == "." || isDirectory(path), !loadingPaths.contains(path),
              force || entriesByPath[path] == nil else { return }
        let currentRevision = revision
        let requestId = UUID()
        requests[path] = requestId
        loadingPaths.insert(path)
        errorsByPath[path] = nil
        defer {
            if owns(path: path, requestId: requestId, revision: currentRevision) {
                requests[path] = nil
                loadingPaths.remove(path)
            }
        }
        do {
            let response = try await connection.request("file.list", params: ["workspaceId": workspaceId, "path": path])
            guard owns(path: path, requestId: requestId, revision: currentRevision), !Task.isCancelled else { return }
            let entries = try WorkspaceFileEntry.parseList(response, directoryPath: path).filter { $0.name != ".git" }
            removeMissingDirectories(in: path, replacingWith: entries)
            entriesByPath[path] = entries
        } catch {
            guard owns(path: path, requestId: requestId, revision: currentRevision),
                  !Task.isCancelled, !(error is CancellationError) else { return }
            errorsByPath[path] = error.localizedDescription
        }
    }

    private func loadExpanded(force: Bool, revision currentRevision: Int) async {
        var visited: Set<String> = []
        while revision == currentRevision, !Task.isCancelled {
            guard let row = rows.first(where: { row in
                row.isDirectory && expandedPaths.contains(row.path) && !visited.contains(row.path)
                    && (force || errorsByPath[row.path] == nil)
            }) else { return }
            visited.insert(row.path)
            await load(path: row.path, force: force)
        }
    }

    private func owns(path: String, requestId: UUID, revision currentRevision: Int) -> Bool {
        revision == currentRevision && requests[path] == requestId
    }

    private func isDirectory(_ path: String) -> Bool {
        let components = path.components(separatedBy: "/")
        let parent = components.count == 1 ? "." : components.dropLast().joined(separator: "/")
        return entriesByPath[parent, default: []].contains { $0.path == path && $0.isDirectory }
    }

    private func removeMissingDirectories(in path: String, replacingWith entries: [WorkspaceFileEntry]) {
        let directories = Set(entries.filter(\.isDirectory).map(\.path))
        let removed = entriesByPath[path, default: []].filter { $0.isDirectory && !directories.contains($0.path) }
        guard !removed.isEmpty else { return }
        let keep: (String) -> Bool = { candidate in
            !removed.contains { candidate == $0.path || candidate.hasPrefix($0.path + "/") }
        }
        entriesByPath = entriesByPath.filter { keep($0.key) }
        expandedPaths = expandedPaths.filter(keep)
        loadingPaths = loadingPaths.filter(keep)
        errorsByPath = errorsByPath.filter { keep($0.key) }
        requests = requests.filter { keep($0.key) }
    }
}
