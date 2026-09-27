import Combine
import Foundation
@testable import Intent
import Testing

/// Opt-in recorder; existing FakeConnectionManager suites keep their behavior.
/// All callers use the production ConnectionManagerRouting surface. Response
/// barriers/errors/cancellation still go through the existing fake implementation.
@MainActor
final class RPCRecordingConnection: FakeConnectionManager {
    private(set) var recordedRequests: [RecordedRPC] = []
    private(set) var recordedNotifications: [RecordedRPCNotification] = []
    private(set) var connectionGeneration = 0
    private var nextOrder = 0
    private let origin = ContinuousClock.now
    /// Fixture responses selected by the actual request params. Use
    /// pendingMethods to pause these; resolvePending then supplies the reply.
    var responseForRequest: ((String, [String: Any]) -> Any?)?

    /// Holds publisher delivery, not connection state or requests. Releasing
    /// emits the current state once so tests control initial connected replay
    /// before binding, during a paused load, or after load has settled.
    var holdsConnectionStateDelivery = false

    override var connectionState: ConnectionState {
        get { super.connectionState }
        set {
            if newValue == .connected, super.connectionState != .connected {
                connectionGeneration += 1
            }
            super.connectionState = newValue
        }
    }

    override var connectionStatePublisher: AnyPublisher<ConnectionState, Never> {
        super.connectionStatePublisher
            .filter { [weak self] _ in self?.holdsConnectionStateDelivery == false }
            .eraseToAnyPublisher()
    }

    func releaseConnectionStateDelivery() {
        holdsConnectionStateDelivery = false
        let current = connectionState
        connectionState = current
    }

    /// Take checkpoints only after setup has settled. The range owns all
    /// completions of requests STARTED in it, including delayed responses.
    var checkpoint: Int { nextOrder }

    func traffic(since checkpoint: Int = 0) -> RPCTraffic {
        RPCTraffic(
            requests: recordedRequests.filter { $0.started.order >= checkpoint },
            notifications: recordedNotifications.filter { $0.received.order >= checkpoint }
        )
    }

    private func milestone() -> RPCMilestone {
        defer { nextOrder += 1 }
        return RPCMilestone(
            order: nextOrder,
            elapsed: origin.duration(to: .now),
            connectionGeneration: connectionGeneration
        )
    }

    override func request(
        _ method: String,
        params: [String: Any] = [:],
        timeout: TimeInterval = ConnectionManager.defaultRequestTimeout
    ) async throws -> Any {
        let index = recordedRequests.count
        recordedRequests.append(RecordedRPC(
            method: method,
            params: params,
            started: milestone(),
            requestJSON: try RPCFixtureJSON.request(method: method, params: params)
        ))
        do {
            if let response = responseForRequest?(method, params) {
                responseMap[method] = response
            }
            let result = try await super.request(method, params: params, timeout: timeout)
            recordedRequests[index].responseJSON = try RPCFixtureJSON.response(result)
            recordedRequests[index].completed = milestone()
            return result
        } catch {
            recordedRequests[index].completed = milestone()
            recordedRequests[index].failure = String(describing: error)
            throw error
        }
    }

    /// Parse the same raw JSON shape the production inbound parser consumes.
    /// Recording occurs once per frame even with zero/multiple local consumers.
    func deliverNotification(params: Any, method: String = "subscription.push") throws {
        try recordNotification(method: method, params: params)
        if method == "subscription.push" {
            let push = try #require(SubscriptionPush.parse(method: method, params: params))
            super.deliverSubscriptionPush(push)
        } else {
            super.deliverEvent(method: method, params: params)
        }
    }

    private func recordNotification(method: String, params: Any) throws {
        let json = try RPCFixtureJSON.notification(method: method, params: params)
        recordedNotifications.append(RecordedRPCNotification(
            method: method, params: params, received: milestone(), json: json
        ))
    }

    override func deliverEvent(method: String, params: Any) {
        guard method != "subscription.push" else { return }
        do {
            try recordNotification(method: method, params: params)
            super.deliverEvent(method: method, params: params)
        } catch {
            Issue.record(error)
        }
    }

    override func deliverSubscriptionPush(_ push: SubscriptionPush) {
        var params: [String: Any] = ["subscriptionId": push.subscriptionId, "seq": push.seq]
        switch push.payload {
        case .collectionSnapshot(let rows):
            params["kind"] = "snapshot"
            params["snapshot"] = rows
        case .conversationSnapshot(let rows, var metadata):
            metadata["messages"] = rows
            params["kind"] = "snapshot"
            params["snapshot"] = metadata
        case .delta(let delta):
            params["kind"] = "delta"
            params["delta"] = ["added": delta.added, "updated": delta.updated, "removedIds": delta.removedIds]
        }
        do {
            try recordNotification(method: "subscription.push", params: params)
            super.deliverSubscriptionPush(push)
        } catch {
            Issue.record(error)
        }
    }

    /// Same surface as the base fake, but snapshots pass through the real
    /// predecoder and the inbound byte ledger rather than a typed shortcut.
    override func registerSubscriptionHandler(id: String, handler: @escaping @MainActor (SubscriptionPush) -> Void) {
        let rows = chatSnapshotMap.removeValue(forKey: id)
        super.registerSubscriptionHandler(id: id, handler: handler)
        guard let rows else { return }
        chatSnapshotMap[id] = rows
        var snapshot = chatSnapshotMetaMap[id] ?? ["truncated": false, "totalMessages": rows.count]
        snapshot["messages"] = rows
        do {
            try deliverNotification(params: [
                "subscriptionId": id, "kind": "snapshot", "seq": 0, "snapshot": snapshot
            ])
        } catch {
            Issue.record(error)
        }
    }
}
