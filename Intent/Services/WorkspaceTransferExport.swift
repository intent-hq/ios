import Combine
import Foundation

/// Keeps the event registration alive before starting the export. Terminal events
/// can precede the start reply; only the reply's export ID selects the result.
@MainActor
final class WorkspaceTransferExport {
    private static let eventTypes = [
        "workspace:transfer:progress", "workspace:transfer:ready", "workspace:transfer:failed"
    ]
    private static let maximumEarlyEvents = 8

    let workspaceId: String
    let source: any SessionConnectionManaging
    let timing: WorkspaceTransferTiming
    let status: (String) -> Void
    private(set) var exportId: String?
    private(set) var didSendStart = false
    private var subscriptionId: String?
    private var eventHandlerId: UUID?
    private var connectionObserver: AnyCancellable?
    private var terminalEvents: [String: Result<[String: Any], Error>] = [:]
    private var failure: Error?
    private var continuation: CheckedContinuation<WorkspaceTransferArchive, Error>?

    init(workspaceId: String, source: any SessionConnectionManaging, timing: WorkspaceTransferTiming, status: @escaping (String) -> Void) {
        self.workspaceId = workspaceId
        self.source = source
        self.timing = timing
        self.status = status
    }

    func start() async throws -> WorkspaceTransferArchive {
        eventHandlerId = source.onEvent { [weak self] method, params in
            self?.receive(method: method, params: params)
        }
        connectionObserver = source.connectionStatePublisher.sink { [weak self] state in
            if state != .connected {
                self?.stop(with: WorkspaceTransferError.message("The source disconnected during transfer. Reconnect and try again."))
            }
        }
        try checkFailure()
        let response = try await source.request("events.subscribe", params: [
            "workspaceId": workspaceId, "eventTypes": Self.eventTypes
        ], timeout: timing.request) as? [String: Any]
        subscriptionId = try WorkspaceTransferWire.identifier(response?["subscriptionId"])
        try checkFailure()
        didSendStart = true
        let started = try await source.request("workspace.export.start", params: ["workspaceId": workspaceId], timeout: timing.request) as? [String: Any]
        exportId = try WorkspaceTransferWire.identifier(started?["exportId"])
        try checkFailure()
        let timer = Task { [weak self, timing] in
            do {
                try await timing.sleep(.seconds(timing.build))
                try Task.checkCancellation()
                self?.stop(with: WorkspaceTransferError.message("The source took too long to prepare the transfer. Try again."))
            } catch { return }
        }
        defer { timer.cancel() }
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            settle()
        }
    }

    func stop(with error: Error = CancellationError()) {
        if failure == nil { failure = error }
        settle()
    }

    func dispose() async {
        if let eventHandlerId { source.removeEventHandler(id: eventHandlerId) }
        eventHandlerId = nil
        connectionObserver = nil
        if let subscriptionId {
            _ = try? await source.request("events.unsubscribe", params: [
                "subscriptionId": subscriptionId, "workspaceId": workspaceId
            ], timeout: timing.cleanup)
        }
        subscriptionId = nil
        terminalEvents.removeAll()
    }

    private func checkFailure() throws {
        if let failure { throw failure }
    }

    private func receive(method: String, params: Any) {
        guard method == "events.event", let params = params as? [String: Any],
              let event = params["event"] as? [String: Any], let type = event["type"] as? String,
              let data = event["data"] as? [String: Any], data["workspaceId"] as? String == workspaceId,
              let eventId = data["exportId"] as? String,
              exportId == nil || exportId == eventId else { return }
        switch type {
        case "workspace:transfer:ready":
            remember(.success(data), exportId: eventId)
        case "workspace:transfer:failed":
            let message = data["reason"] as? String ?? "The source could not prepare the transfer."
            remember(.failure(WorkspaceTransferError.message(message)), exportId: eventId)
        case "workspace:transfer:progress":
            if failure == nil { status(Self.stageMessage(data["stage"] as? String)) }
        default: return
        }
    }

    private func remember(_ result: Result<[String: Any], Error>, exportId: String) {
        guard terminalEvents[exportId] != nil || terminalEvents.count < Self.maximumEarlyEvents else { return }
        terminalEvents[exportId] = result
        settle()
    }

    private func settle() {
        guard let continuation else { return }
        if let failure {
            self.continuation = nil
            continuation.resume(throwing: failure)
        } else if let exportId, let result = terminalEvents[exportId] {
            self.continuation = nil
            continuation.resume(with: Result {
                try WorkspaceTransferArchive(data: result.get(), workspaceId: workspaceId, exportId: exportId)
            })
        }
    }

    private static func stageMessage(_ stage: String?) -> String {
        switch stage {
        case "stopping-agents": "Stopping running agents…"
        case "exporting-rows": "Preparing workspace data…"
        case "bundling-git": "Preparing repository files…"
        case "writing-archive": "Building the transfer archive…"
        default: "Preparing the transfer…"
        }
    }
}
