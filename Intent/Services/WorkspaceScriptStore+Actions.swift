import Foundation

extension WorkspaceScriptStore {
    func cancelActionLaunch(_ script: WorkspaceScript) {
        let workspaceId = script.workspaceId
        if let launch = pending[workspaceId],
           let candidate = discovered[workspaceId]?.first(where: { $0.id == launch.scriptId }),
           candidate.name == script.name || candidate.command == script.command { pending[workspaceId] = nil }
        clearLaunch(scriptId: script.id, workspaceId: workspaceId)
    }

    func performAction(_ script: WorkspaceScript, method: String) async {
        guard isConnected, script.isRegistered, !isUpdating(script) else { return }
        let workspaceId = script.workspaceId
        let key = ScriptKey(workspaceId: workspaceId, scriptId: script.id)
        let token = UUID()
        let currentGeneration = generation
        updates[key] = token
        errors[workspaceId] = nil
        observedWorkspaces.insert(workspaceId)
        cancelActionLaunch(script)
        revisions[workspaceId, default: 0] += 1
        defer { finishUpdate(key, token: token, generation: currentGeneration) }
        do {
            // A previously sent start must settle before stop/remove can win.
            if let start = startTasks[key] { _ = try? await start.value }
            guard isCurrent(currentGeneration) else { return }
            try await ensureSubscribed(generation: currentGeneration)
            guard isCurrent(currentGeneration) else { return }
            let response = try await connection.request(method, params: ["workspaceId": workspaceId, "scriptId": script.id])
            guard isCurrent(currentGeneration), updates[key] == token else { return }
            guard let result = response as? [String: Any], result["ok"] as? Bool == true else {
                throw WorkspaceScriptError.invalidResponse
            }
            revisions[workspaceId, default: 0] += 1
            if method == "script.remove" {
                definitions[workspaceId]?.removeAll { $0.id == script.id }
            } else {
                try await refreshStoppedScript(script, generation: currentGeneration)
            }
        } catch {
            guard isCurrent(currentGeneration), updates[key] == token else { return }
            errors[workspaceId] = error.localizedDescription
        }
    }

    private func finishUpdate(_ key: ScriptKey, token: UUID, generation currentGeneration: Int) {
        guard generation == currentGeneration, updates[key] == token else { return }
        updates[key] = nil
        revisions[key.workspaceId, default: 0] += 1
    }

    private func refreshStoppedScript(_ script: WorkspaceScript, generation currentGeneration: Int) async throws {
        let workspaceId = script.workspaceId
        while isCurrent(currentGeneration) {
            let revision = revisions[workspaceId, default: 0]
            do {
                let response = try await connection.request("script.status", params: ["workspaceId": workspaceId, "scriptId": script.id])
                guard isCurrent(currentGeneration) else { return }
                guard revisions[workspaceId, default: 0] == revision else { continue }
                guard let runtime = response as? [String: Any], runtime["status"] is String else {
                    throw WorkspaceScriptError.invalidResponse
                }
                var current = definitions[workspaceId]?.first { $0.id == script.id } ?? script
                current.apply(runtime: runtime)
                update(current)
                revisions[workspaceId, default: 0] += 1
                return
            } catch {
                guard isCurrent(currentGeneration) else { return }
                guard revisions[workspaceId, default: 0] == revision else { continue }
                throw error
            }
        }
    }
}
