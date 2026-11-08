import Foundation

@MainActor
enum WorkspaceScriptRepository {
    private struct RegistrationKey: Hashable {
        let connection: ObjectIdentifier
        let workspaceId: String
        let candidateId: String
    }

    private static var registrations: [RegistrationKey: Task<WorkspaceScript, Error>] = [:]

    static func discover(connection: ConnectionManagerRouting, workspaceId: String) async -> [WorkspaceScript] {
        guard let response = try? await connection.request("file.list", params: ["workspaceId": workspaceId, "path": "."]),
              let entries = response as? [[String: Any]], !Task.isCancelled else { return [] }
        let names = Set(entries.compactMap { $0["name"] as? String })
        var files: [String: String] = [:]
        for path in WorkspaceScriptDiscovery.manifestPaths where names.contains(path) {
            guard !Task.isCancelled else { return [] }
            let response = try? await connection.request("file.read", params: ["workspaceId": workspaceId, "path": path])
            files[path] = response as? String ?? (response as? [String: Any])?["content"] as? String
        }
        return WorkspaceScriptDiscovery.scripts(workspaceId: workspaceId, files: files, fileNames: names)
    }

    static func register(_ candidate: WorkspaceScript, connection: ConnectionManagerRouting) async throws -> WorkspaceScript {
        let key = RegistrationKey(connection: ObjectIdentifier(connection), workspaceId: candidate.workspaceId, candidateId: candidate.id)
        if let task = registrations[key] { return try await task.value }
        let task = Task {
            // Every page: a matching script on a later page must not be created again.
            let response = try await PagedReads.requestAllScripts(workspaceId: candidate.workspaceId) { params in
                try await connection.request("script.list", params: params)
            }
            guard connection.connectionState == .connected, !Task.isCancelled else { throw CancellationError() }
            guard let result = response as? [String: Any], let rows = result["scripts"] as? [[String: Any]] else {
                throw WorkspaceScriptError.invalidResponse
            }
            let scripts = rows.compactMap { WorkspaceScript(definition: $0, workspaceId: candidate.workspaceId) }
            if let existing = scripts.first(where: { $0.name == candidate.name })
                ?? scripts.first(where: { $0.command == candidate.command }) { return existing }
            let created = try await connection.request("script.create", params: [
                "workspaceId": candidate.workspaceId, "name": candidate.name,
                "command": candidate.command, "mode": candidate.mode
            ])
            guard let definition = created as? [String: Any],
                  let script = WorkspaceScript(definition: definition, workspaceId: candidate.workspaceId) else {
                throw WorkspaceScriptError.invalidResponse
            }
            return script
        }
        registrations[key] = task
        defer { registrations[key] = nil }
        return try await task.value
    }
}
