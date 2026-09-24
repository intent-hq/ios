import Combine
import Foundation
import Observation

@MainActor
@Observable
final class AssistantStore {
    private(set) var threads: [AgentSession] = []
    private(set) var isLoading = false
    private(set) var isCreating = false
    private(set) var hasLoaded = false
    private(set) var errorMessage: String?

    @ObservationIgnored private let connection: any ConnectionManagerRouting
    @ObservationIgnored private var eventHandlerId: UUID?
    @ObservationIgnored private var connectionObserver: AnyCancellable?
    private var refreshRequested = false
    private var creationKey: String?

    init(connection: any ConnectionManagerRouting) {
        self.connection = connection
        eventHandlerId = connection.onEvent { [weak self] method, params in
            Task { @MainActor [weak self] in
                self?.handleEvent(method, params: params)
            }
        }
        connectionObserver = connection.connectionStatePublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                guard let self, state == .connected, hasLoaded else { return }
                Task { await self.refresh() }
            }
    }

    isolated deinit {
        if let eventHandlerId {
            connection.removeEventHandler(id: eventHandlerId)
        }
    }

    func refresh() async {
        guard !isLoading else {
            refreshRequested = true
            return
        }
        isLoading = true
        defer { isLoading = false }
        repeat {
            refreshRequested = false
            do {
                let result = try await connection.request(
                    "agent.list", params: ["workspaceId": Workspace.chiefWorkspaceId]
                )
                try Task.checkCancellation()
                guard let response = result as? [String: Any],
                      let rows = response["agents"] as? [[String: Any]] else {
                    throw AssistantError.invalidResponse
                }
                threads = rows.compactMap(AgentSession.parseAgent)
                    .filter { $0.createdByAgentId == nil && $0.status.lowercased() != "deleted" }
                    .sorted { timestamp($0) > timestamp($1) }
                hasLoaded = true
                errorMessage = nil
            } catch is CancellationError {
                return
            } catch {
                errorMessage = error.localizedDescription
                return
            }
        } while refreshRequested
    }

    func createThread() async -> String? {
        guard !isCreating else { return nil }
        isCreating = true
        errorMessage = nil
        defer { isCreating = false }
        let key = creationKey ?? UUID().uuidString
        creationKey = key
        do {
            let result = try await connection.request("agent.create", params: [
                "workspaceId": Workspace.chiefWorkspaceId,
                "specialistId": "chief-of-staff",
                "name": "Assistant",
                "nameExplicitlySet": false,
                "idempotencyKey": key
            ])
            guard let response = result as? [String: Any],
                  let row = response["agent"] as? [String: Any],
                  let agent = AgentSession.parseAgent(row) else {
                throw AssistantError.invalidResponse
            }
            creationKey = nil
            threads.removeAll { $0.id == agent.id }
            threads.insert(agent, at: 0)
            hasLoaded = true
            if isLoading { refreshRequested = true }
            return agent.id
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    func removeThread(_ agentId: String) {
        threads.removeAll { $0.id == agentId }
    }

    private func timestamp(_ agent: AgentSession) -> Date {
        ISO8601DateFormatter.lenientDate(from: agent.bestTimestamp) ?? .distantPast
    }

    private func handleEvent(_: String, params: Any) {
        guard hasLoaded, let payload = params as? [String: Any] else { return }
        let event = payload["event"] as? [String: Any] ?? payload
        guard event["workspaceId"] as? String == Workspace.chiefWorkspaceId,
              let type = event["type"] as? String,
              Self.threadEvents.contains(type) else { return }
        Task { await self.refresh() }
    }

    private static let threadEvents: Set<String> = [
        "agent:created", "agent:deleted", "agent:renamed", "agent:retired", "agent:restored"
    ]

    private enum AssistantError: LocalizedError {
        case invalidResponse

        var errorDescription: String? {
            "The server returned an unreadable Assistant response. Please try again."
        }
    }
}
