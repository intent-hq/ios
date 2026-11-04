import Combine
import Foundation
import Observation

@MainActor
@Observable
final class WorkspaceBrowserStore {
    private static let methodNotFoundCode = -32_601
    private static let eventTypes = [
        "script:state", "script:changed", "browser:tab-opened", "browser:tab-updated", "browser:tab-closed"
    ]

    private(set) var isConnected: Bool
    private var saved: [WorkspaceBrowser]
    private var detected: [String: [WorkspaceBrowser]] = [:]
    private var tabs: [String: [WorkspaceBrowser]] = [:]
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
        dismissed = persistence.loadDismissed()
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
        let hiddenIds = dismissed[workspaceId, default: []]
        // Filter sources first so a dismissed script cannot consume an unrelated
        // tab during merging, or reappear as a tab once the script stops.
        let servers = WorkspaceBrowser.merging(
            scripts: detected[workspaceId, default: []].filter { !hiddenIds.contains($0.id) },
            tabs: tabs[workspaceId, default: []].filter { !hiddenIds.contains($0.id) }
        )
        let discoveredURLs = Set(servers.map(\.url))
        return servers + saved.filter { $0.workspaceId == workspaceId && !discoveredURLs.contains($0.url) }
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

    func open(workspaceId: String, url: String) throws -> WorkspaceBrowser {
        let normalized = try WorkspaceBrowserURL.normalize(url)
        if let existing = browsers(workspaceId: workspaceId).first(where: { $0.url == normalized }) {
            return existing
        }
        return try create(workspaceId: workspaceId, url: normalized)
    }

    func remove(_ browser: WorkspaceBrowser) {
        if browser.isSavedSession {
            saved.removeAll { $0.id == browser.id && $0.workspaceId == browser.workspaceId }
        } else {
            let matchingTabs = tabs[browser.workspaceId, default: []].filter { $0.url == browser.url }
            dismissed[browser.workspaceId, default: []].formUnion(matchingTabs.map(\.id) + [browser.id])
            saved.removeAll { $0.workspaceId == browser.workspaceId && $0.url == browser.url }
            persistence.saveDismissed(dismissed)
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
                let scripts = await discovery(workspaceId: workspaceId, method: "script.list", key: "scripts")
                guard isCurrent(currentGeneration), revisions[workspaceId, default: 0] == revision else { continue }
                let browserTabs = await discovery(workspaceId: workspaceId, method: "browser.listTabs", key: "tabs")
                // Events can invalidate a list already in flight. Coalesce all of them
                // into one trailing fetch rather than publishing the stale snapshot.
                guard isCurrent(currentGeneration), revisions[workspaceId, default: 0] == revision else { continue }
                if scripts.error == nil { detected[workspaceId] = scripts.browsers }
                if browserTabs.error == nil { tabs[workspaceId] = browserTabs.browsers }
                errors[workspaceId] = scripts.error ?? browserTabs.error
                return
            } catch {
                guard isCurrent(currentGeneration), revisions[workspaceId, default: 0] == revision else { continue }
                errors[workspaceId] = error.localizedDescription
                return
            }
        }
    }

    private func discovery(workspaceId: String, method: String, key: String) async -> (browsers: [WorkspaceBrowser], error: String?) {
        do {
            let response: Any
            if method == "script.list" {
                response = try await PagedReads.requestAllScripts(workspaceId: workspaceId) { [connection] params in
                    try await connection.request(method, params: params)
                }
            } else {
                response = try await connection.request(method, params: ["workspaceId": workspaceId])
            }
            guard let result = response as? [String: Any], let rows = result[key] as? [[String: Any]] else {
                throw WorkspaceBrowserError.invalidResponse
            }
            var seen: Set<String> = []
            let browsers = rows.compactMap { row in
                key == "scripts"
                    ? WorkspaceBrowser.detected(script: row, workspaceId: workspaceId)
                    : WorkspaceBrowser.detected(tab: row, workspaceId: workspaceId)
            }
            .filter { seen.insert($0.id).inserted }
            return (browsers, nil)
        } catch {
            if method == "browser.listTabs", (error as NSError).code == Self.methodNotFoundCode {
                return ([], nil)
            }
            return ([], error.localizedDescription)
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
                    "eventTypes": Self.eventTypes, "replaceGroup": "ios-workspace-browsers"
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
        tabs.removeAll()
        errors.removeAll()
        if isConnected {
            for workspaceId in observedWorkspaces { _ = refreshTask(workspaceId: workspaceId) }
        }
    }

    private func handleEvent(_ method: String, params: Any) {
        guard isConnected, method == "events.event", let envelope = params as? [String: Any],
              let event = envelope["event"] as? [String: Any],
              let type = event["type"] as? String, Self.eventTypes.contains(type),
              let workspaceId = event["workspaceId"] as? String, observedWorkspaces.contains(workspaceId),
              let data = event["data"] as? [String: Any] else { return }
        guard let subscriptionId, envelope["subscriptionId"] as? String == subscriptionId else { return }
        if type.hasPrefix("browser:") {
            guard applyTabEvent(type, data: data, workspaceId: workspaceId) else { return }
        } else {
            guard let scriptId = data["scriptId"] as? String else { return }
            let stopped = type == "script:state" && data["status"] as? String != "running"
            let removed = type == "script:changed" && data["action"] as? String == "removed"
            if stopped || removed { detected[workspaceId]?.removeAll { $0.id == "script:\(scriptId)" } }
        }
        revisions[workspaceId, default: 0] += 1
        _ = refreshTask(workspaceId: workspaceId)
    }

    private func applyTabEvent(_ type: String, data: [String: Any], workspaceId: String) -> Bool {
        guard let tab = data["tab"] as? [String: Any],
              tab["workspaceId"] as? String == workspaceId,
              let id = tab["tabId"] as? String, !id.isEmpty else { return false }
        let browser = WorkspaceBrowser.detected(tab: tab, workspaceId: workspaceId)
        let index = tabs[workspaceId, default: []].firstIndex { $0.id == "tab:\(id)" }
        if type == "browser:tab-closed" || browser == nil {
            tabs[workspaceId]?.removeAll { $0.id == "tab:\(id)" }
        } else if let browser {
            if let index {
                tabs[workspaceId]?[index] = browser
            } else {
                tabs[workspaceId, default: []].append(browser)
            }
        }
        return true
    }
}
