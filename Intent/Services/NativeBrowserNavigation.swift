import Combine
import Foundation
import Observation

/// Logical native browser sessions. Only the presented session has a WKWebView;
/// registry visibility never implies page load or browser automation support.
@MainActor
@Observable
final class NativeBrowserNavigation {
    static let actions: Set<String> = ["openTab", "showTab", "focusTab", "closeTab", "navigate"]
    private(set) var tabs: [NativeBrowserTab] = []
    private(set) var presentedID: String?
    private(set) var presenterID: UUID?
    private(set) var registryError: String?
    @ObservationIgnored var savedBrowsers: (String) -> [WorkspaceBrowser] = { _ in [] }
    @ObservationIgnored let connection: any ConnectionManagerRouting
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let persistenceKey: String?
    @ObservationIgnored private var windows: [UUID] = []
    @ObservationIgnored private var eventHandlerID: UUID?
    @ObservationIgnored private var connectionObserver: AnyCancellable?
    @ObservationIgnored private var reportTask: Task<Void, Error>?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var executing = false
    @ObservationIgnored private var needsReconciliation = true

    init(connection: any ConnectionManagerRouting, backendID: BackendID? = nil, defaults: UserDefaults = .standard) {
        self.connection = connection
        self.defaults = defaults
        persistenceKey = backendID.map { "nativeBrowserTabs.\($0.connectionID.uuidString)" }
        if let persistenceKey, let data = defaults.data(forKey: persistenceKey),
           let restored = try? JSONDecoder().decode([NativeBrowserTab].self, from: data) {
            tabs = restored.filter { (try? WorkspaceBrowserURL.normalize($0.url)) == $0.url }.map { tab in
                var tab = tab
                tab.displayed = false
                return tab
            }
        }
        eventHandlerID = connection.onEvent { [weak self] method, params in
            self?.receiveEvent(method, params: params)
        }
        connectionObserver = connection.connectionStatePublisher.removeDuplicates().dropFirst().sink { [weak self] state in
            guard let self else { return }
            generation += 1
            needsReconciliation = true
            if state == .connected { scheduleReport() }
        }
    }

    isolated deinit {
        if let eventHandlerID { connection.removeEventHandler(id: eventHandlerID) }
    }

    func browsers(workspaceId: String) -> [WorkspaceBrowser] {
        tabs.filter { $0.workspaceId == workspaceId }.map { tab in
            WorkspaceBrowser(id: tab.id, workspaceId: tab.workspaceId, title: tab.title, url: tab.url, command: nil)
        }
    }

    func presentation(window: UUID) -> WorkspaceBrowser? {
        guard presenterID == window else { return nil }
        return tabs.first { $0.id == presentedID }?.browser
    }

    func setWindow(_ id: UUID, active: Bool) {
        windows.removeAll { $0 == id }
        if active { windows.append(id) }
        if presenterID == id, !active, let presentedID { setDisplayed(presentedID, false) }
    }

    func presentUserBrowser(_ browser: WorkspaceBrowser) {
        let existing = tabs.first { $0.id == browser.id || ($0.workspaceId == browser.workspaceId && NativeBrowserTab.matches($0.url, browser.url)) }
        let tab = existing ?? NativeBrowserTab(
            id: "ios-\(UUID().uuidString.lowercased())",
            workspaceId: browser.workspaceId,
            ownerAgentId: nil,
            requestedURL: browser.url,
            url: browser.url,
            title: browser.title
        )
        if existing == nil { tabs.append(tab) }
        present(tab.id)
        scheduleReport()
    }

    func dismiss(window: UUID) {
        guard presenterID == window else { return }
        if let presentedID { setDisplayed(presentedID, false) }
        presentedID = nil
        presenterID = nil
    }

    func setDisplayed(_ id: String, _ displayed: Bool) {
        guard let index = tabs.firstIndex(where: { $0.id == id }), tabs[index].displayed != displayed else { return }
        tabs[index].displayed = displayed
        scheduleReport()
    }

    func pageChanged(_ id: String, url: String, title: String) {
        guard let index = tabs.firstIndex(where: { $0.id == id }),
              let normalized = try? WorkspaceBrowserURL.normalize(url) else { return }
        guard tabs[index].url != normalized || tabs[index].title != title else { return }
        tabs[index].url = normalized
        if !title.isEmpty { tabs[index].title = title }
        scheduleReport()
    }

    func remove(_ browser: WorkspaceBrowser) {
        guard tabs.contains(where: { $0.id == browser.id }) else { return }
        tabs.removeAll { $0.id == browser.id }
        if presentedID == browser.id { presentedID = nil }
        scheduleReport()
    }

    func execute(_ params: [String: Any]) async -> [String: Any] {
        guard let actions = params["actions"] as? [[String: Any]], !actions.isEmpty else {
            return failure("", code: "invalid-params", message: "A nonempty navigation action list is required.")
        }
        // Reject mixed automation batches before opening even the first tab.
        if let unsupported = actions.first(where: { !Self.actions.contains($0["action"] as? String ?? "") }) {
            return failure(
                unsupported["action"] as? String ?? "",
                code: "browser-automation-unavailable",
                message: "The native browser supports navigation only, not screenshots or page automation."
            )
        }
        guard !executing else { return failure("", code: "browser-busy", message: "Another navigation request is in progress.") }
        guard let workspace = params["workspaceId"] as? String, !workspace.isEmpty else {
            return failure("", code: "invalid-params", message: "A workspace is required.")
        }
        executing = true
        defer { executing = false }
        let currentGeneration = generation
        let principal = (connection as? any SessionConnectionManaging)?.currentPrincipal
        var results: [[String: Any]] = []
        for action in actions {
            let name = action["action"] as? String ?? ""
            do {
                guard connection.connectionState == .connected, generation == currentGeneration,
                      (connection as? any SessionConnectionManaging)?.currentPrincipal == principal else { throw BrowserTunnelError.closed }
                let result = try apply(
                    action,
                    workspace: workspace,
                    agent: params["agentId"] as? String,
                    defaultTab: params["tabId"] as? String
                )
                try await report().value
                guard generation == currentGeneration, connection.connectionState == .connected else { throw BrowserTunnelError.closed }
                if let id = result["tabId"] as? String, name != "closeTab", !tabs.contains(where: { $0.id == id }) {
                    throw NativeBrowserFailure(code: "tab-not-found", message: "The daemon no longer accepts this tab.")
                }
                results.append(["action": name, "success": true, "result": result])
            } catch {
                let failure = (error as? NativeBrowserFailure) ?? NativeBrowserFailure(code: "browser-navigation-failed", message: error.localizedDescription)
                results.append(failure.envelope(action: name))
                return ["success": false, "results": results, "error": failure.message]
            }
        }
        return ["success": true, "results": results]
    }

    private func apply(_ action: [String: Any], workspace: String, agent: String?, defaultTab: String?) throws -> [String: Any] {
        let name = action["action"] as? String ?? ""
        let id: String
        if name == "openTab" {
            id = try open(action, workspace: workspace, agent: agent)
        } else {
            guard let value = action["tabId"] as? String ?? defaultTab else {
                throw NativeBrowserFailure(code: "invalid-params", message: "A tab ID is required.")
            }
            id = value
        }
        guard let index = tabs.firstIndex(where: { $0.id == id && $0.workspaceId == workspace }) else {
            throw NativeBrowserFailure(code: "tab-not-found", message: "This native browser tab is not available.")
        }
        try checkOwner(tabs[index], agent: agent, mutating: name == "navigate" || name == "closeTab")
        switch name {
        case "closeTab":
            tabs.remove(at: index)
            if presentedID == id { presentedID = nil }
            return ["tabId": id, "closed": true]
        case "navigate":
            let url = try address(action)
            tabs[index].requestedURL = url
            tabs[index].loadURL = url
            tabs[index].url = url
        case "showTab", "focusTab":
            try requireWindow()
            present(id)
        default: break
        }
        return [
            "tabId": id, "url": tabs[index].url, "title": tabs[index].title,
            "accepted": true, "displayed": tabs[index].displayed,
            "capabilities": ["browserNavigation": true, "browserExec": false]
        ]
    }

    private func open(_ action: [String: Any], workspace: String, agent: String?) throws -> String {
        let url = try address(action)
        let visible = action["visible"] as? Bool ?? true
        if visible { try requireWindow() }
        if let tab = tabs.first(where: { $0.workspaceId == workspace && (NativeBrowserTab.matches($0.url, url) || NativeBrowserTab.matches($0.requestedURL, url)) }) {
            try checkOwner(tab, agent: agent, mutating: false)
            if visible { present(tab.id) }
            return tab.id
        }
        let saved = savedBrowsers(workspace).first { NativeBrowserTab.matches($0.url, url) }
        let tab = NativeBrowserTab(
            id: "ios-\(UUID().uuidString.lowercased())",
            workspaceId: workspace,
            ownerAgentId: saved == nil ? agent : nil,
            requestedURL: url,
            url: url,
            title: saved?.title ?? url
        )
        tabs.append(tab)
        if visible { present(tab.id) }
        return tab.id
    }

    private func address(_ action: [String: Any]) throws -> String {
        guard let raw = action["url"] as? String else { throw WorkspaceBrowserError.invalidURL }
        return try WorkspaceBrowserURL.normalize(raw)
    }

    private func checkOwner(_ tab: NativeBrowserTab, agent: String?, mutating: Bool) throws {
        // Missing agent identity is the daemon's authenticated human operation.
        guard let agent else { return }
        if let owner = tab.ownerAgentId, owner != agent {
            throw NativeBrowserFailure(code: "not-owner", message: "This tab belongs to another agent.", ownerAgentId: owner)
        }
        if mutating, tab.ownerAgentId == nil {
            throw NativeBrowserFailure(code: "not-owner", message: "Agents cannot navigate or close a user tab.")
        }
    }

    private func requireWindow() throws {
        guard !windows.isEmpty else {
            throw NativeBrowserFailure(code: "browser-navigation-unavailable", message: "Open Intent on this device to show the preview.")
        }
    }

    private func present(_ id: String) {
        guard let window = presenterID.flatMap({ windows.contains($0) ? $0 : nil }) ?? windows.last else { return }
        if let old = presentedID, old != id { setDisplayed(old, false) }
        if let index = tabs.firstIndex(where: { $0.id == id }) {
            if presentedID != id { tabs[index].loadURL = tabs[index].url }
            tabs[index].visible = true
        }
        presenterID = window
        presentedID = id
    }

    private func failure(_ action: String, code: String, message: String) -> [String: Any] {
        ["success": false, "results": [NativeBrowserFailure(code: code, message: message).envelope(action: action)], "error": message]
    }
}

extension NativeBrowserNavigation {
    private func receiveEvent(_ method: String, params: Any) {
        guard connection.connectionState == .connected, method == "events.event" || method == "event",
              let envelope = params as? [String: Any] else { return }
        let event = envelope["event"] as? [String: Any] ?? envelope
        if event["type"] as? String == "workspace:deleted", let workspace = event["workspaceId"] as? String {
            tabs.removeAll { $0.workspaceId == workspace }
            if let presentedID, !tabs.contains(where: { $0.id == presentedID }) { self.presentedID = nil }
            persist()
            return
        }
        guard let type = event["type"] as? String,
              let data = event["data"] as? [String: Any], let tab = data["tab"] as? [String: Any],
              let id = tab["tabId"] as? String,
              let index = tabs.firstIndex(where: { $0.id == id && $0.workspaceId == tab["workspaceId"] as? String }) else { return }
        if type == "browser:tab-closed" {
            tabs.remove(at: index)
            if presentedID == id { presentedID = nil }
        } else if type == "browser:tab-updated" {
            tabs[index].ownerAgentId = tab["ownerAgentId"] as? String
        }
        persist()
    }

    /// Serialize snapshots so a delayed UI report cannot resurrect a closed tab.
    private func report() -> Task<Void, Error> {
        persist()
        let previous = reportTask
        let currentGeneration = generation
        let principal = (connection as? any SessionConnectionManaging)?.currentPrincipal
        let task = Task { [weak self] in
            _ = try? await previous?.value
            guard let self, generation == currentGeneration, connection.connectionState == .connected,
                  (connection as? any SessionConnectionManaging)?.currentPrincipal == principal else { throw BrowserTunnelError.closed }
            if needsReconciliation, !tabs.isEmpty {
                let response = try await connection.request("workspace.list", params: ["includeArchived": true])
                guard generation == currentGeneration,
                      (connection as? any SessionConnectionManaging)?.currentPrincipal == principal else { throw BrowserTunnelError.closed }
                guard let result = response as? [String: Any], let rows = result["workspaces"] as? [[String: Any]] else {
                    throw WorkspaceBrowserError.invalidResponse
                }
                let accessible = Set(rows.compactMap { $0["id"] as? String })
                tabs.removeAll { !accessible.contains($0.workspaceId) }
                if let presentedID, !tabs.contains(where: { $0.id == presentedID }) { self.presentedID = nil }
                needsReconciliation = false
            }
            let response = try await connection.request("browser.syncTabs", params: ["tabs": tabs.map(\.report)])
            guard generation == currentGeneration else { throw BrowserTunnelError.closed }
            guard let response = response as? [String: Any], let dropped = response["drop"] as? [String] else {
                throw WorkspaceBrowserError.invalidResponse
            }
            tabs.removeAll { dropped.contains($0.id) }
            if let presentedID, dropped.contains(presentedID) { self.presentedID = nil }
            persist()
            registryError = nil
        }
        reportTask = task
        return task
    }

    private func persist() {
        guard let persistenceKey, let data = try? JSONEncoder().encode(tabs) else { return }
        defaults.set(data, forKey: persistenceKey)
    }

    private func scheduleReport() {
        let task = report()
        Task { [weak self] in
            do { try await task.value } catch { self?.registryError = error.localizedDescription }
        }
    }
}
