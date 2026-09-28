import Combine
import Foundation
import Observation

/// Owned by one workspace view so only the launching window presents its browser.
@MainActor
@Observable
final class WorkspaceScriptStore {
    private struct Launch {
        let id = UUID()
        let scriptId: String
        var observing = false
    }

    private struct ScriptKey: Hashable {
        let workspaceId: String
        let scriptId: String
    }

    private static let eventTypes = ["script:state", "script:changed"]
    private(set) var isConnected: Bool
    private var definitions: [String: [WorkspaceScript]] = [:]
    private var errors: [String: String] = [:]
    private var loadErrors: [String: String] = [:]
    private var pending: [String: Launch] = [:]
    private var presentations: [String: WorkspaceBrowser] = [:]

    @ObservationIgnored private let connection: ConnectionManagerRouting
    @ObservationIgnored private let replaceGroup = "ios-workspace-scripts-\(UUID().uuidString)"
    @ObservationIgnored private var cancellable: AnyCancellable?
    @ObservationIgnored private var eventHandlerId: UUID?
    @ObservationIgnored private var subscriptionTask: Task<String, Error>?
    @ObservationIgnored private var subscriptionId: String?
    @ObservationIgnored private var refreshTasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var startTasks: [ScriptKey: Task<Void, Error>] = [:]
    @ObservationIgnored private var revisions: [String: Int] = [:]
    @ObservationIgnored private var observedWorkspaces: Set<String> = []
    @ObservationIgnored private var generation = 0

    init(connection: ConnectionManagerRouting) {
        self.connection = connection
        isConnected = connection.connectionState == .connected
        eventHandlerId = connection.onEvent { [weak self] method, params in
            self?.handleEvent(method, params: params)
        }
        cancellable = connection.connectionStatePublisher
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] state in self?.connectionChanged(state) }
    }

    isolated deinit {
        subscriptionTask?.cancel()
        for task in refreshTasks.values { task.cancel() }
        for task in startTasks.values { task.cancel() }
        if let eventHandlerId { connection.removeEventHandler(id: eventHandlerId) }
        if let subscriptionId {
            Task { [connection] in
                _ = try? await connection.request("events.unsubscribe", params: ["subscriptionId": subscriptionId])
            }
        }
    }

    func scripts(workspaceId: String) -> [WorkspaceScript] { definitions[workspaceId, default: []] }

    func errorMessage(workspaceId: String) -> String? { errors[workspaceId] ?? loadErrors[workspaceId] }

    func isLaunching(_ script: WorkspaceScript) -> Bool {
        guard let launch = pending[script.workspaceId], launch.scriptId == script.id else { return false }
        if !launch.observing { return true }
        let status = definitions[script.workspaceId]?.first { $0.id == script.id }?.status ?? script.status
        return status == "starting" || status == "restarting"
    }

    func browserToOpen(workspaceId: String) -> WorkspaceBrowser? { presentations[workspaceId] }

    func takeBrowserToOpen(workspaceId: String) -> WorkspaceBrowser? {
        presentations.removeValue(forKey: workspaceId)
    }

    func cancelPendingLaunch(workspaceId: String) {
        pending[workspaceId] = nil
        presentations[workspaceId] = nil
    }

    func refresh(workspaceId: String) async {
        observedWorkspaces.insert(workspaceId)
        guard isConnected else { return }
        await refreshTask(workspaceId: workspaceId).value
    }

    func launch(_ script: WorkspaceScript) async {
        let workspaceId = script.workspaceId
        guard isConnected, pending[workspaceId]?.scriptId != script.id else { return }
        let launch = Launch(scriptId: script.id)
        let currentGeneration = generation
        observedWorkspaces.insert(workspaceId)
        pending[workspaceId] = launch
        presentations[workspaceId] = nil
        errors[workspaceId] = nil
        defer {
            if Task.isCancelled, pending[workspaceId]?.id == launch.id { cancelPendingLaunch(workspaceId: workspaceId) }
        }
        do {
            try await performLaunch(script, launch: launch, generation: currentGeneration)
        } catch {
            guard owns(launch, workspaceId: workspaceId, generation: currentGeneration) else { return }
            errors[workspaceId] = error.localizedDescription
            cancelPendingLaunch(workspaceId: workspaceId)
        }
    }

    private func performLaunch(_ script: WorkspaceScript, launch: Launch, generation currentGeneration: Int) async throws {
        let workspaceId = script.workspaceId
        try await ensureSubscribed(generation: currentGeneration)
        guard owns(launch, workspaceId: workspaceId, generation: currentGeneration) else { return }
        // Reselecting a script whose start is in flight shares that request.
        let key = ScriptKey(workspaceId: workspaceId, scriptId: script.id)
        let existingStart = startTasks[key]
        if let existingStart { try await existingStart.value }
        guard var current = try await currentScript(script, launch: launch, generation: currentGeneration) else { return }
        if existingStart == nil, !current.isActive {
            guard owns(launch, workspaceId: workspaceId, generation: currentGeneration) else { return }
            try await start(current, generation: currentGeneration)
            guard owns(launch, workspaceId: workspaceId, generation: currentGeneration) else { return }
            guard let started = try await currentScript(script, launch: launch, generation: currentGeneration) else { return }
            current = started
        }
        guard owns(launch, workspaceId: workspaceId, generation: currentGeneration) else { return }
        pending[workspaceId]?.observing = true
        considerPresentation(current)
    }

    private func owns(_ launch: Launch, workspaceId: String, generation currentGeneration: Int) -> Bool {
        isCurrent(currentGeneration) && pending[workspaceId]?.id == launch.id
    }

    private func currentScript(_ script: WorkspaceScript, launch: Launch, generation currentGeneration: Int) async throws -> WorkspaceScript? {
        let workspaceId = script.workspaceId
        while owns(launch, workspaceId: workspaceId, generation: currentGeneration) {
            let revision = revisions[workspaceId, default: 0]
            let response = try await connection.request("script.status", params: ["workspaceId": workspaceId, "scriptId": script.id])
            guard owns(launch, workspaceId: workspaceId, generation: currentGeneration) else { return nil }
            guard revisions[workspaceId, default: 0] == revision else { continue }
            guard let runtime = response as? [String: Any], runtime["status"] is String else {
                throw WorkspaceScriptError.invalidResponse
            }
            var current = definitions[workspaceId]?.first { $0.id == script.id } ?? script
            current.apply(runtime: runtime)
            update(current)
            // A list captured before this authoritative status must not restore old fields.
            revisions[workspaceId, default: 0] += 1
            return current
        }
        return nil
    }

    private func start(_ script: WorkspaceScript, generation currentGeneration: Int) async throws {
        let key = ScriptKey(workspaceId: script.workspaceId, scriptId: script.id)
        if let task = startTasks[key] {
            try await task.value
            return
        }
        revisions[script.workspaceId, default: 0] += 1
        var starting = script
        starting.apply(runtime: ["status": "starting"])
        update(starting)
        let task = Task { [connection] in
            let response = try await connection.request("script.start", params: ["workspaceId": script.workspaceId, "scriptId": script.id])
            guard let result = response as? [String: Any], result["ok"] as? Bool == true else {
                throw WorkspaceScriptError.invalidResponse
            }
        }
        startTasks[key] = task
        defer {
            if generation == currentGeneration {
                startTasks[key] = nil
                revisions[script.workspaceId, default: 0] += 1
            }
        }
        try await task.value
    }

    private func update(_ script: WorkspaceScript) {
        if let index = definitions[script.workspaceId]?.firstIndex(where: { $0.id == script.id }) {
            definitions[script.workspaceId]?[index] = script
        }
        if presentations[script.workspaceId]?.id == "script:\(script.id)" {
            presentations[script.workspaceId] = script.browser
        }
    }

    private func considerPresentation(_ script: WorkspaceScript) {
        guard let launch = pending[script.workspaceId], launch.scriptId == script.id, launch.observing else { return }
        if let browser = script.browser {
            presentations[script.workspaceId] = browser
            pending[script.workspaceId] = nil
        } else if !script.isActive {
            errors[script.workspaceId] = script.error
            cancelPendingLaunch(workspaceId: script.workspaceId)
        }
    }
}

private extension WorkspaceScriptStore {
    func refreshTask(workspaceId: String) -> Task<Void, Never> {
        if let task = refreshTasks[workspaceId] { return task }
        let currentGeneration = generation
        let task = Task { [weak self] in
            guard let self else { return }
            await fetch(workspaceId: workspaceId, generation: currentGeneration)
        }
        refreshTasks[workspaceId] = task
        return task
    }

    func fetch(workspaceId: String, generation currentGeneration: Int) async {
        defer { if generation == currentGeneration { refreshTasks[workspaceId] = nil } }
        while isCurrent(currentGeneration) {
            let revision = revisions[workspaceId, default: 0]
            do {
                try await ensureSubscribed(generation: currentGeneration)
                guard isCurrent(currentGeneration) else { return }
                let response = try await connection.request("script.list", params: ["workspaceId": workspaceId])
                guard isCurrent(currentGeneration), revisions[workspaceId, default: 0] == revision else { continue }
                guard let result = response as? [String: Any], let rows = result["scripts"] as? [[String: Any]] else {
                    throw WorkspaceScriptError.invalidResponse
                }
                var seen: Set<String> = []
                let scripts = rows.compactMap { WorkspaceScript(definition: $0, workspaceId: workspaceId) }
                    .filter { seen.insert($0.id).inserted }
                definitions[workspaceId] = scripts
                loadErrors[workspaceId] = nil
                if let launch = pending[workspaceId], !scripts.contains(where: { $0.id == launch.scriptId }) {
                    cancelPendingLaunch(workspaceId: workspaceId)
                }
                if let browser = presentations[workspaceId], !scripts.contains(where: { $0.browser == browser }) {
                    presentations[workspaceId] = nil
                }
                for script in scripts { considerPresentation(script) }
                return
            } catch {
                guard isCurrent(currentGeneration), revisions[workspaceId, default: 0] == revision else { continue }
                loadErrors[workspaceId] = error.localizedDescription
                return
            }
        }
    }

    func ensureSubscribed(generation currentGeneration: Int) async throws {
        if subscriptionId != nil { return }
        let task: Task<String, Error>
        if let existing = subscriptionTask {
            task = existing
        } else {
            task = Task { [connection, replaceGroup] in
                let response = try await connection.request("events.subscribe", params: [
                    "eventTypes": Self.eventTypes, "replaceGroup": replaceGroup
                ])
                guard let result = response as? [String: Any],
                      let id = result["subscriptionId"] as? String, !id.isEmpty else {
                    throw WorkspaceScriptError.invalidResponse
                }
                return id
            }
            subscriptionTask = task
        }
        defer { if generation == currentGeneration { subscriptionTask = nil } }
        let id = try await task.value
        guard isCurrent(currentGeneration) else { return }
        subscriptionId = id
    }

    func isCurrent(_ currentGeneration: Int) -> Bool {
        isConnected && generation == currentGeneration && !Task.isCancelled
    }

    func connectionChanged(_ state: ConnectionState) {
        generation += 1
        isConnected = state == .connected
        subscriptionTask?.cancel()
        subscriptionTask = nil
        subscriptionId = nil
        for task in refreshTasks.values { task.cancel() }
        for task in startTasks.values { task.cancel() }
        refreshTasks.removeAll()
        startTasks.removeAll()
        definitions.removeAll()
        pending.removeAll()
        presentations.removeAll()
        errors.removeAll()
        loadErrors.removeAll()
        if isConnected {
            for workspaceId in observedWorkspaces { _ = refreshTask(workspaceId: workspaceId) }
        }
    }

    func handleEvent(_ method: String, params: Any) {
        guard isConnected, method == "events.event", let envelope = params as? [String: Any],
              let subscriptionId, envelope["subscriptionId"] as? String == subscriptionId,
              let event = envelope["event"] as? [String: Any],
              let type = event["type"] as? String, Self.eventTypes.contains(type),
              let workspaceId = event["workspaceId"] as? String, observedWorkspaces.contains(workspaceId),
              let data = event["data"] as? [String: Any], let scriptId = data["scriptId"] as? String else { return }
        revisions[workspaceId, default: 0] += 1
        if type == "script:changed" {
            if data["action"] as? String == "removed" {
                definitions[workspaceId]?.removeAll { $0.id == scriptId }
                clearLaunch(scriptId: scriptId, workspaceId: workspaceId)
            }
            _ = refreshTask(workspaceId: workspaceId)
        } else {
            applyState(data, scriptId: scriptId, workspaceId: workspaceId)
        }
    }

    func applyState(_ runtime: [String: Any], scriptId: String, workspaceId: String) {
        guard let status = runtime["status"] as? String else { return }
        if status == "idle" || status == "exited" {
            if pending[workspaceId]?.scriptId == scriptId { errors[workspaceId] = runtime["error"] as? String }
            clearLaunch(scriptId: scriptId, workspaceId: workspaceId)
        } else if status != "running", presentations[workspaceId]?.id == "script:\(scriptId)" {
            presentations[workspaceId] = nil
        }
        guard var script = definitions[workspaceId]?.first(where: { $0.id == scriptId }) else {
            _ = refreshTask(workspaceId: workspaceId)
            return
        }
        script.apply(runtime: runtime)
        update(script)
        considerPresentation(script)
    }

    func clearLaunch(scriptId: String, workspaceId: String) {
        if pending[workspaceId]?.scriptId == scriptId { pending[workspaceId] = nil }
        if presentations[workspaceId]?.id == "script:\(scriptId)" { presentations[workspaceId] = nil }
    }
}
