import Combine
import Foundation
import Observation

@MainActor
@Observable
final class WorkspaceBrowserStore {
    private(set) var isConnected: Bool
    private var saved: [WorkspaceBrowser]
    private var detected: [String: [WorkspaceBrowser]] = [:]
    private var dismissed: [String: Set<String>] = [:]
    private var errors: [String: String] = [:]

    @ObservationIgnored private let connection: ConnectionManagerRouting
    @ObservationIgnored private let persistence: WorkspaceBrowserPersistence
    @ObservationIgnored private var cancellable: AnyCancellable?
    @ObservationIgnored private var eventHandlerId: UUID?
    @ObservationIgnored private var subscriptionTask: Task<String, Error>?
    @ObservationIgnored private var subscriptionId: String?
    @ObservationIgnored private var refreshTasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var revisions: [String: Int] = [:]
    @ObservationIgnored private var observedWorkspaces: Set<String> = []
    @ObservationIgnored private var generation = 0

    init(connection: ConnectionManagerRouting, backendID: BackendID?, defaults: UserDefaults = .standard) {
        self.connection = connection
        persistence = WorkspaceBrowserPersistence(backendID: backendID, defaults: defaults)
        saved = persistence.load()
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
        if let eventHandlerId { connection.removeEventHandler(id: eventHandlerId) }
    }

    func browsers(workspaceId: String) -> [WorkspaceBrowser] {
        let servers = detected[workspaceId, default: []].filter { browser in
            !dismissed[workspaceId, default: []].contains(browser.id)
        }
        return servers + saved.filter { $0.workspaceId == workspaceId }
    }

    func errorMessage(workspaceId: String) -> String? { errors[workspaceId] }

    func refresh(workspaceId: String) async {
        observedWorkspaces.insert(workspaceId)
        guard isConnected else { return }
        await refreshTask(workspaceId: workspaceId).value
    }

    func create(workspaceId: String, url: String) throws -> WorkspaceBrowser {
        let normalized = try WorkspaceBrowserURL.normalize(url)
        let browser = WorkspaceBrowser(
            id: "browser:\(UUID().uuidString)",
            workspaceId: workspaceId,
            title: normalized,
            url: normalized,
            command: nil
        )
        saved.append(browser)
        persistence.save(saved)
        return browser
    }

    func remove(_ browser: WorkspaceBrowser) {
        saved.removeAll { $0.id == browser.id && $0.workspaceId == browser.workspaceId }
        if browser.command != nil, browser.id.hasPrefix("script:") {
            dismissed[browser.workspaceId, default: []].insert(browser.id)
        }
        persistence.save(saved)
    }

    private func refreshTask(workspaceId: String) -> Task<Void, Never> {
        if let task = refreshTasks[workspaceId] { return task }
        let currentGeneration = generation
        let task = Task { [weak self] in
            guard let self else { return }
            await fetch(workspaceId: workspaceId, generation: currentGeneration)
        }
        refreshTasks[workspaceId] = task
        return task
    }

    private func fetch(workspaceId: String, generation currentGeneration: Int) async {
        defer { if generation == currentGeneration { refreshTasks[workspaceId] = nil } }
        while isCurrent(currentGeneration) {
            let revision = revisions[workspaceId, default: 0]
            do {
                try await ensureSubscribed(generation: currentGeneration)
                guard isCurrent(currentGeneration) else { return }
                let response = try await connection.request("script.list", params: ["workspaceId": workspaceId])
                guard isCurrent(currentGeneration) else { return }
                // Events can invalidate a list already in flight. Coalesce all of them
                // into one trailing fetch rather than publishing the stale snapshot.
                guard revisions[workspaceId, default: 0] == revision else { continue }
                guard let result = response as? [String: Any],
                      let scripts = result["scripts"] as? [[String: Any]] else {
                    throw WorkspaceBrowserError.invalidResponse
                }
                var seen: Set<String> = []
                detected[workspaceId] = scripts.compactMap { WorkspaceBrowser.detected(script: $0, workspaceId: workspaceId) }
                    .filter { seen.insert($0.id).inserted }
                errors[workspaceId] = nil
                return
            } catch {
                guard isCurrent(currentGeneration) else { return }
                guard revisions[workspaceId, default: 0] == revision else { continue }
                errors[workspaceId] = error.localizedDescription
                return
            }
        }
    }

    private func ensureSubscribed(generation currentGeneration: Int) async throws {
        if subscriptionId != nil { return }
        let task: Task<String, Error>
        if let existing = subscriptionTask {
            task = existing
        } else {
            task = Task { [connection] in
                let response = try await connection.request("events.subscribe", params: [
                    "eventTypes": ["script:state", "script:changed"], "replaceGroup": "ios-workspace-browsers"
                ])
                guard let result = response as? [String: Any],
                      let id = result["subscriptionId"] as? String, !id.isEmpty else {
                    throw WorkspaceBrowserError.invalidResponse
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

    private func isCurrent(_ currentGeneration: Int) -> Bool {
        isConnected && generation == currentGeneration && !Task.isCancelled
    }

    private func connectionChanged(_ state: ConnectionState) {
        generation += 1
        isConnected = state == .connected
        subscriptionTask?.cancel()
        subscriptionTask = nil
        subscriptionId = nil
        for task in refreshTasks.values { task.cancel() }
        refreshTasks.removeAll()
        detected.removeAll()
        errors.removeAll()
        if isConnected {
            for workspaceId in observedWorkspaces { _ = refreshTask(workspaceId: workspaceId) }
        }
    }

    private func handleEvent(_ method: String, params: Any) {
        guard isConnected, method == "events.event", let envelope = params as? [String: Any],
              let event = envelope["event"] as? [String: Any],
              let type = event["type"] as? String, ["script:state", "script:changed"].contains(type),
              let workspaceId = event["workspaceId"] as? String, observedWorkspaces.contains(workspaceId),
              let data = event["data"] as? [String: Any], let scriptId = data["scriptId"] as? String else { return }
        if let subscriptionId, envelope["subscriptionId"] as? String != subscriptionId { return }
        revisions[workspaceId, default: 0] += 1
        let stopped = type == "script:state" && data["status"] as? String != "running"
        let removed = type == "script:changed" && data["action"] as? String == "removed"
        if stopped || removed {
            detected[workspaceId]?.removeAll { $0.id == "script:\(scriptId)" }
        }
        _ = refreshTask(workspaceId: workspaceId)
    }
}
