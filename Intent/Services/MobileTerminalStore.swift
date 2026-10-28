import Combine
import Foundation
import Observation

@MainActor
@Observable
final class MobileTerminalStore {
    private(set) var terminals: [MobileTerminal]
    private(set) var creatingWorkspaces: Set<String> = []
    private(set) var connectionGeneration = 0
    private(set) var isConnected: Bool
    /// Errors are keyed by workspace so a background refresh of one workspace
    /// never surfaces on another workspace's screen.
    private(set) var errors: [String: String] = [:]

    @ObservationIgnored let connection: ConnectionManagerRouting
    @ObservationIgnored private let persistence: MobileTerminalPersistence
    @ObservationIgnored private var cancellable: AnyCancellable?
    @ObservationIgnored private var eventHandlerId: UUID?
    @ObservationIgnored private var subscriptionTask: Task<Void, Error>?
    @ObservationIgnored private var subscriptionId: String?
    @ObservationIgnored private var verifiedIds: Set<String> = []
    @ObservationIgnored private var revisions: [String: Int] = [:]
    @ObservationIgnored private var observedWorkspaces: Set<String> = []

    init(connection: ConnectionManagerRouting, persistence: MobileTerminalPersistence) {
        self.connection = connection
        self.persistence = persistence
        terminals = persistence.load()
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
        if let eventHandlerId { connection.removeEventHandler(id: eventHandlerId) }
    }

    func activeTerminals(workspaceId: String) -> [MobileTerminal] {
        terminals.filter { $0.workspaceId == workspaceId && verifiedIds.contains($0.id) }
    }

    func isActive(_ terminal: MobileTerminal) -> Bool {
        terminals.contains(terminal) && verifiedIds.contains(terminal.id)
    }

    func errorMessage(workspaceId: String) -> String? { errors[workspaceId] }

    func clearError(workspaceId: String) { errors[workspaceId] = nil }

    func refresh(workspaceId: String) async {
        observedWorkspaces.insert(workspaceId)
        guard isConnected, terminals.contains(where: { $0.workspaceId == workspaceId }) else { return }
        do {
            try await ensureSubscribed()
            _ = try await reconcile(workspaceId: workspaceId)
            errors[workspaceId] = nil
        } catch {
            errors[workspaceId] = error.localizedDescription
        }
    }

    func openOrCreate(workspaceId: String) async -> MobileTerminal? {
        if terminals.contains(where: { $0.workspaceId == workspaceId }) {
            await refresh(workspaceId: workspaceId)
            guard errorMessage(workspaceId: workspaceId) == nil else { return nil }
            if let terminal = activeTerminals(workspaceId: workspaceId).first { return terminal }
        }
        return await create(workspaceId: workspaceId)
    }

    func create(workspaceId: String) async -> MobileTerminal? {
        guard creatingWorkspaces.insert(workspaceId).inserted else { return nil }
        observedWorkspaces.insert(workspaceId)
        defer { creatingWorkspaces.remove(workspaceId) }
        errors[workspaceId] = nil
        let generation = connectionGeneration
        do {
            try await ensureSubscribed()
            let bootId = try await reconcile(workspaceId: workspaceId)
            try checkConnection(generation)
            let response = try await connection.request("terminal.create", params: [
                "workspaceId": workspaceId,
                "cols": MobileTerminalConnection.initialColumns,
                "rows": MobileTerminalConnection.initialRows
            ])
            // A returned id means the shell is running on the daemon, so record it even
            // if the connection changed meanwhile; dropping it would orphan the PTY.
            guard let result = response as? [String: Any],
                  let id = result["terminalId"] as? String, !id.isEmpty else {
                throw MobileTerminalError.invalidResponse
            }
            let terminal = MobileTerminal(
                id: id,
                workspaceId: workspaceId,
                daemonBootId: bootId,
                name: nextName(workspaceId: workspaceId)
            )
            terminals.append(terminal)
            verifiedIds.insert(id)
            changed(workspaceId)
            if generation != connectionGeneration, isConnected {
                Task { [weak self] in await self?.refresh(workspaceId: workspaceId) }
            }
            return terminal
        } catch {
            errors[workspaceId] = error.localizedDescription
            return nil
        }
    }

    func close(_ terminal: MobileTerminal) async -> Bool {
        let generation = connectionGeneration
        errors[terminal.workspaceId] = nil
        do {
            try await validate(terminal)
            try checkConnection(generation)
            _ = try await connection.request("terminal.kill", params: ["terminalId": terminal.id])
            remove(terminal)
            return true
        } catch MobileTerminalError.sessionEnded {
            remove(terminal)
            return true
        } catch {
            errors[terminal.workspaceId] = error.localizedDescription
            return false
        }
    }

    func validate(_ terminal: MobileTerminal) async throws {
        _ = try await reconcile(workspaceId: terminal.workspaceId)
        guard isActive(terminal) else { throw MobileTerminalError.sessionEnded }
    }

    func checkConnection(_ generation: Int) throws {
        guard isConnected, connection.connectionState == .connected,
              generation == connectionGeneration else { throw MobileTerminalError.disconnected }
    }

    private func reconcile(workspaceId: String) async throws -> String {
        let generation = connectionGeneration
        try checkConnection(generation)
        let revision = revisions[workspaceId, default: 0]
        let response = try await connection.request("terminal.list", params: ["workspaceId": workspaceId])
        try checkConnection(generation)
        guard let result = response as? [String: Any],
              let bootId = result["daemonBootId"] as? String, !bootId.isEmpty,
              let rows = result["terminals"] as? [[String: Any]] else {
            throw MobileTerminalError.invalidResponse
        }
        let liveIds = Set(rows.compactMap { $0["id"] as? String })
        if revisions[workspaceId, default: 0] == revision {
            terminals.removeAll { terminal in
                terminal.workspaceId == workspaceId && (terminal.daemonBootId != bootId || !liveIds.contains(terminal.id))
            }
            verifiedIds.formUnion(terminals.filter { $0.workspaceId == workspaceId }.map(\.id))
            persistence.save(terminals)
        }
        return bootId
    }

    private func ensureSubscribed() async throws {
        let generation = connectionGeneration
        try checkConnection(generation)
        if subscriptionId != nil { return }
        if let subscriptionTask {
            try await subscriptionTask.value
            return
        }
        let task = Task { @MainActor in
            let response = try await self.connection.request("events.subscribe", params: [
                "eventTypes": ["terminal:exit"], "replaceGroup": "ios-mobile-terminals"
            ])
            try self.checkConnection(generation)
            guard let result = response as? [String: Any],
                  let id = result["subscriptionId"] as? String else {
                throw MobileTerminalError.invalidResponse
            }
            self.subscriptionId = id
        }
        subscriptionTask = task
        defer { if connectionGeneration == generation { subscriptionTask = nil } }
        try await task.value
    }

    private func connectionChanged(_ state: ConnectionState) {
        connectionGeneration += 1
        isConnected = state == .connected
        subscriptionTask?.cancel()
        subscriptionTask = nil
        subscriptionId = nil
        if isConnected {
            Task { [weak self] in
                guard let self else { return }
                for workspaceId in observedWorkspaces { await refresh(workspaceId: workspaceId) }
            }
        }
    }

    private func handleEvent(_ method: String, params: Any) {
        guard method == "events.event", let envelope = params as? [String: Any],
              let event = envelope["event"] as? [String: Any],
              event["type"] as? String == "terminal:exit",
              let data = event["data"] as? [String: Any],
              let id = data["terminalId"] as? String,
              let terminal = terminals.first(where: { terminal in
                  terminal.id == id && terminal.workspaceId == event["workspaceId"] as? String
              }) else { return }
        remove(terminal)
    }

    private func remove(_ terminal: MobileTerminal) {
        terminals.removeAll { $0 == terminal }
        verifiedIds.remove(terminal.id)
        changed(terminal.workspaceId)
    }

    private func changed(_ workspaceId: String) {
        revisions[workspaceId, default: 0] += 1
        persistence.save(terminals)
    }

    private func nextName(workspaceId: String) -> String {
        let names = Set(terminals.filter { $0.workspaceId == workspaceId }.map(\.name))
        var number = 1
        while names.contains("Terminal \(number)") { number += 1 }
        return "Terminal \(number)"
    }
}
