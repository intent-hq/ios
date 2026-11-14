import Combine
import Foundation
@testable import Intent
import Network
import os
import Testing

nonisolated final class RecoveryWebSocketServer: @unchecked Sendable {
        private static let scriptedFailureCode = -32_000

        enum PongPolicy {
            case automatic
            case replied
            case withheld
        }

        /// Admission requests a reconnect candidate must answer before
        /// `ConnectionManager` adopts it (`WebSocketAdmission`).
        private static let handshakeMethods: Set<String> = ["client.hello", "principal.me"]

        private struct HeldResponse {
            let payload: Data
            let connection: NWConnection
        }

        private struct State {
            var accepted: [NWConnection] = []
            var pingsReceived = 0
            var requestCounts: [String: Int] = [:]
            var scriptedFailures: [String: Int] = [:]
            var holdsHandshakes = false
            var heldResponses: [HeldResponse] = []
        }

        private let listener: NWListener
        private let queue = DispatchQueue(label: "ConnectionManagerTests.recovery-server")
        private let pongs: PongPolicy
        private let state = OSAllocatedUnfairLock(initialState: State())

        var port: Int { Int(listener.port?.rawValue ?? 0) }
        var pingsReceived: Int { state.withLock { $0.pingsReceived } }

        private init(listener: NWListener, pongs: PongPolicy) {
            self.listener = listener
            self.pongs = pongs
        }

        static func start(
            pongs: PongPolicy = .automatic
        ) async throws -> RecoveryWebSocketServer {
            let parameters = NWParameters.tcp
            let options = NWProtocolWebSocket.Options()
            options.autoReplyPing = pongs == .automatic
            parameters.defaultProtocolStack.applicationProtocols.insert(options, at: 0)
            let server = RecoveryWebSocketServer(
                listener: try NWListener.loopback(using: parameters),
                pongs: pongs
            )
            server.listener.newConnectionHandler = { [weak server] connection in
                guard let server else { return }
                server.state.withLock { $0.accepted.append(connection) }
                server.receiveNext(on: connection)
                connection.start(queue: server.queue)
            }
            let resumed = OSAllocatedUnfairLock(initialState: false)
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                server.listener.stateUpdateHandler = { listenerState in
                    switch listenerState {
                    case .ready, .failed, .cancelled:
                        let didResume = resumed.withLock { state in
                            defer { state = true }
                            return state
                        }
                        if !didResume { continuation.resume() }
                    default:
                        break
                    }
                }
                server.listener.start(queue: server.queue)
            }
            return server
        }

        func requestCount(method: String) -> Int {
            state.withLock { $0.requestCounts[method] ?? 0 }
        }

        func failNextRequests(_ count: Int, method: String) {
            state.withLock { $0.scriptedFailures[method] = count }
        }

        /// Admission replies parked by `holdHandshakes()`; a non-zero count
        /// means a replacement connection reached this server and is waiting.
        var heldHandshakeCount: Int { state.withLock { $0.heldResponses.count } }

        /// Gate for asserting a transient reconnecting state: until
        /// `releaseHandshakes()`, admission replies are parked, so no
        /// replacement connection can be adopted however fast it dials.
        func holdHandshakes() {
            state.withLock { $0.holdsHandshakes = true }
        }

        /// Opens the gate and delivers every parked admission reply in order.
        func releaseHandshakes() {
            let held = state.withLock { state in
                defer {
                    state.holdsHandshakes = false
                    state.heldResponses.removeAll()
                }
                return state.heldResponses
            }
            for response in held { send(response.payload, on: response.connection) }
        }

        func stop() {
            listener.cancel()
            let connections = state.withLock { state in
                defer { state.accepted.removeAll() }
                return state.accepted
            }
            for connection in connections { connection.cancel() }
        }

        func dropClients() {
            let connections = state.withLock { state in
                defer { state.accepted.removeAll() }
                return state.accepted
            }
            for connection in connections { connection.cancel() }
        }

        private func receiveNext(on connection: NWConnection) {
            connection.receiveMessage { [weak self] data, context, _, error in
                guard let self, error == nil else { return }
                let metadata = context?.protocolMetadata(definition: NWProtocolWebSocket.definition)
                    as? NWProtocolWebSocket.Metadata
                if metadata?.opcode == .ping {
                    receivePing(data: data, on: connection)
                } else if let data,
                          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                          let id = json["id"] {
                    receiveRequest(json, id: id, on: connection)
                }
                receiveNext(on: connection)
            }
        }

        private func receivePing(data: Data?, on connection: NWConnection) {
            state.withLock { $0.pingsReceived += 1 }
            guard pongs == .replied else { return }
            let metadata = NWProtocolWebSocket.Metadata(opcode: .pong)
            let context = NWConnection.ContentContext(identifier: "pong", metadata: [metadata])
            connection.send(
                content: data,
                contentContext: context,
                isComplete: true,
                completion: .idempotent
            )
        }

        private func receiveRequest(
            _ json: [String: Any],
            id: Any,
            on connection: NWConnection
        ) {
            let method = json["method"] as? String ?? ""
            let fails = state.withLock { state in
                state.requestCounts[method, default: 0] += 1
                guard let remaining = state.scriptedFailures[method], remaining > 0 else {
                    return false
                }
                state.scriptedFailures[method] = remaining - 1
                return true
            }
            var response: [String: Any] = ["jsonrpc": "2.0", "id": id]
            if fails {
                response["error"] = [
                    "code": Self.scriptedFailureCode,
                    "message": "scripted failure"
                ]
            } else if method == "principal.me" {
                response["result"] = ["id": "test-owner", "isAdministrator": true]
            } else if method == "client.hello" {
                response["result"] = ["server": ["protocolVersion": ProtocolFixtures.currentProtocolVersion, "capabilities": [String: Int]()]]
            } else {
                response["result"] = [String: Any]()
            }
            guard let payload = try? JSONSerialization.data(withJSONObject: response) else { return }
            let held = state.withLock { state in
                guard state.holdsHandshakes, Self.handshakeMethods.contains(method) else { return false }
                state.heldResponses.append(HeldResponse(payload: payload, connection: connection))
                return true
            }
            if !held { send(payload, on: connection) }
        }

        private func send(_ payload: Data, on connection: NWConnection) {
            let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
            let context = NWConnection.ContentContext(identifier: "response", metadata: [metadata])
            connection.send(content: payload, contentContext: context, completion: .idempotent)
        }
}

nonisolated final class ManualHeartbeatClock: HeartbeatClock, @unchecked Sendable {
        private struct Sleeper {
            let id: Int
            let duration: Duration
            let deadline: Duration
            let continuation: CheckedContinuation<Void, any Error>
        }

        private struct State {
            var now: Duration = .zero
            var nextID = 0
            var sleepers: [Sleeper] = []
            var held: [Sleeper] = []
            var holdsCancelledSleepers = false
        }

        private let lock = OSAllocatedUnfairLock(initialState: State())

        var pendingDurations: [Duration] { lock.withLock { $0.sleepers.map(\.duration) } }
        var heldDurations: [Duration] { lock.withLock { $0.held.map(\.duration) } }
        var holdsCancelledSleepers: Bool {
            get { lock.withLock { $0.holdsCancelledSleepers } }
            set { lock.withLock { $0.holdsCancelledSleepers = newValue } }
        }

        func sleep(for duration: Duration) async throws {
            let id = lock.withLock { state in
                state.nextID += 1
                return state.nextID
            }
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    let parked = lock.withLock { state in
                        let sleeper = Sleeper(
                            id: id,
                            duration: duration,
                            deadline: state.now + duration,
                            continuation: continuation
                        )
                        if Task.isCancelled {
                            guard state.holdsCancelledSleepers else { return false }
                            state.held.append(sleeper)
                        } else {
                            state.sleepers.append(sleeper)
                        }
                        return true
                    }
                    if !parked { continuation.resume(throwing: CancellationError()) }
                }
            } onCancel: {
                let cancelled = lock.withLock { state -> Sleeper? in
                    guard let index = state.sleepers.firstIndex(where: { $0.id == id }) else {
                        return nil
                    }
                    let sleeper = state.sleepers.remove(at: index)
                    if state.holdsCancelledSleepers {
                        state.held.append(sleeper)
                        return nil
                    }
                    return sleeper
                }
                cancelled?.continuation.resume(throwing: CancellationError())
            }
        }

        func releaseHeld(asCompleted: Bool) {
            let sleepers = lock.withLock { state in
                defer { state.held.removeAll() }
                return state.held
            }
            for sleeper in sleepers {
                if asCompleted {
                    sleeper.continuation.resume()
                } else {
                    sleeper.continuation.resume(throwing: CancellationError())
                }
            }
        }

        func advance(by duration: Duration) {
            let sleepers = lock.withLock { state in
                state.now += duration
                let due = state.sleepers.filter { $0.deadline <= state.now }
                state.sleepers.removeAll { $0.deadline <= state.now }
                return due
            }
            for sleeper in sleepers { sleeper.continuation.resume() }
        }
}

extension ConnectionManagerTests {
    // Test polling bounds intentionally use short wall-clock durations.
    // swiftlint:disable no_magic_numbers
    private static let defaultSettleTimeout: Duration = .seconds(3)
    // swiftlint:enable no_magic_numbers

    @MainActor final class DisconnectCounter {
        private(set) var count = 0
        private var wasReconnecting: Bool
        private var cancellable: AnyCancellable?

        init(_ manager: ConnectionManager) {
            if case .reconnecting = manager.connectionState {
                wasReconnecting = true
            } else {
                wasReconnecting = false
            }
            cancellable = manager.connectionStatePublisher.sink { [weak self] state in
                guard let self else { return }
                let reconnecting: Bool
                if case .reconnecting = state { reconnecting = true } else { reconnecting = false }
                if reconnecting, !wasReconnecting { count += 1 }
                wasReconnecting = reconnecting
            }
        }
    }

    /// Holds `server`'s admission replies, runs `trigger`, and returns once a
    /// replacement connection is parked at admission. Until the caller's
    /// `server.releaseHandshakes()`, the manager cannot adopt a replacement,
    /// so an intermediate "reconnecting" assertion cannot race a fast
    /// recovery (ios#261).
    @MainActor static func awaitParkedReplacement(
        on server: RecoveryWebSocketServer,
        timeout: Duration = Self.defaultSettleTimeout,
        sourceLocation: SourceLocation = #_sourceLocation,
        after trigger: @MainActor () -> Void
    ) async throws {
        server.holdHandshakes()
        trigger()
        try await waitUntil(
            "a replacement connection to wait at admission",
            timeout: timeout,
            sourceLocation: sourceLocation
        ) { server.heldHandshakeCount > 0 }
    }

    static func isReconnecting(_ state: ConnectionState) -> Bool {
        if case .reconnecting = state { return true }
        return false
    }

    /// Bounded wait for the manager to reach `condition`; throws
    /// `ConditionWaitFailure` naming the call site on timeout so the test
    /// fails at the wait instead of at whichever assertion follows.
    @MainActor static func settle(
        timeout: Duration = Self.defaultSettleTimeout,
        sourceLocation: SourceLocation = #_sourceLocation,
        until condition: @MainActor () -> Bool
    ) async throws {
        try await waitUntil(
            "connection manager to settle",
            timeout: timeout,
            sourceLocation: sourceLocation
        ) { condition() }
    }
}
