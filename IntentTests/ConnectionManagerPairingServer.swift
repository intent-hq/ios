import Foundation
@testable import Intent
import Network
import os

extension ConnectionManagerTests {
    /// Loopback plain-WS listener with a minimal JSON-RPC responder: any
    /// request carrying an `id` gets an empty-object result; notifications
    /// are ignored. Lets `connect()` tests establish real sockets and prove
    /// a connection still serves round-trips. Nonisolated for the same
    /// reason as ManualTokenEntryViewTests' TLS listener: the handlers run
    /// on the listener queue and must not inherit MainActor isolation.
    nonisolated private struct LoopbackWebSocketServerState {
        var accepted: [NWConnection] = []
        // Connections held back by a gated server: accepted but not
        // started, so the client's WS handshake stays pending until
        // `open()` releases them. Lets tests control which of two
        // racing connect() calls completes first.
        var pendingStart: [NWConnection] = []
        var isOpen: Bool
        var acceptedTotal = 0
        var principal: [String: Any] = ["id": "test-owner", "isAdministrator": true]
        var modern = false
        var helloIDs: [String] = []
    }

    nonisolated final class LoopbackWebSocketServer: @unchecked Sendable {
        private let listener: NWListener
        private let queue = DispatchQueue(label: "ConnectionManagerTests.ws-server")
        // Retain accepted connections for the listener's lifetime (an
        // unreferenced NWConnection deallocates and drops the socket).
        private let state: OSAllocatedUnfairLock<LoopbackWebSocketServerState>

        var port: Int { Int(listener.port?.rawValue ?? 0) }
        var acceptedCount: Int { state.withLock { $0.acceptedTotal } }
        var helloIDs: [String] { state.withLock { $0.helloIDs } }

        func setPrincipal(_ principal: [String: Any], modern: Bool = true) {
            state.withLock { $0.principal = principal; $0.modern = modern }
        }

        func dropConnections() {
            state.withLock { state in
                for connection in state.accepted { connection.cancel() }
                state.accepted.removeAll()
            }
        }

        private init(listener: NWListener, gated: Bool) {
            self.listener = listener
            self.state = OSAllocatedUnfairLock(
                initialState: LoopbackWebSocketServerState(isOpen: !gated)
            )
        }

        static func start(gated: Bool = false) async throws -> LoopbackWebSocketServer {
            let parameters = NWParameters.tcp
            let wsOptions = NWProtocolWebSocket.Options()
            wsOptions.autoReplyPing = true
            parameters.defaultProtocolStack.applicationProtocols.insert(wsOptions, at: 0)
            let server = LoopbackWebSocketServer(
                listener: try NWListener(using: parameters, on: .any),
                gated: gated
            )
            server.listener.newConnectionHandler = { [weak server] connection in
                guard let server else { return }
                let startNow = server.state.withLock { state in
                    state.accepted.append(connection)
                    state.acceptedTotal += 1
                    if !state.isOpen { state.pendingStart.append(connection) }
                    return state.isOpen
                }
                guard startNow else { return }
                server.receiveNext(on: connection)
                connection.start(queue: server.queue)
            }
            let resumed = OSAllocatedUnfairLock(initialState: false)
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                server.listener.stateUpdateHandler = { state in
                    switch state {
                    case .ready, .failed, .cancelled:
                        let alreadyResumed = resumed.withLock { (done: inout Bool) -> Bool in
                            let was = done
                            done = true
                            return was
                        }
                        if !alreadyResumed { continuation.resume() }
                    default:
                        break
                    }
                }
                server.listener.start(queue: server.queue)
            }
            return server
        }

        /// Releases a gated server: starts every held-back connection so
        /// their pending WS handshakes complete, and starts future ones
        /// immediately.
        func open() {
            let held = state.withLock { state in
                state.isOpen = true
                let pending = state.pendingStart
                state.pendingStart.removeAll()
                return pending
            }
            for connection in held {
                receiveNext(on: connection)
                connection.start(queue: queue)
            }
        }

        func stop() {
            listener.cancel()
            state.withLock { state in
                for connection in state.accepted { connection.cancel() }
                state.accepted.removeAll()
                state.pendingStart.removeAll()
            }
        }

        private func response(to json: [String: Any]) -> [String: Any] {
            state.withLock { state -> [String: Any] in
                if json["method"] as? String == "principal.me" { return state.principal }
                if json["method"] as? String == "client.hello",
                   let parameters = json["params"] as? [String: Any], let clientID = parameters["clientId"] as? String {
                    state.helloIDs.append(clientID)
                }
                return ["server": ["capabilities": state.modern ? ["hostMembership": 1] : [String: Int]()]]
            }
        }

        private func receiveNext(on connection: NWConnection) {
            connection.receiveMessage { [weak self] data, _, _, error in
                guard let self, error == nil else { return }
                if let data,
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let id = json["id"] {
                    let response: [String: Any] = [
                        "jsonrpc": "2.0",
                        "id": id,
                        "result": response(to: json)
                    ]
                    if let payload = try? JSONSerialization.data(withJSONObject: response) {
                        let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
                        let context = NWConnection.ContentContext(
                            identifier: "response",
                            metadata: [metadata]
                        )
                        connection.send(
                            content: payload,
                            contentContext: context,
                            completion: .idempotent
                        )
                    }
                }
                receiveNext(on: connection)
            }
        }
    }
}
