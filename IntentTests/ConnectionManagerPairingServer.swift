import Foundation
@testable import Intent
import Network
import os
import Security
import Testing

extension ConnectionManagerTests {
    nonisolated private struct HeldReply: Sendable {
        let connection: NWConnection
        let data: Data
        let method: String
    }
    /// Loopback plain-WS listener with a minimal JSON-RPC responder: any
    /// request carrying an `id` gets an empty-object result; notifications
    /// are ignored. Lets `connect()` tests establish real sockets and prove
    /// a connection still serves round-trips. Nonisolated for the same
    /// reason as ManualTokenEntryViewTests' TLS listener: the handlers run
    /// on the listener queue and must not inherit MainActor isolation.
    nonisolated private struct LoopbackWebSocketServerState: Sendable {
        var accepted: [NWConnection] = []
        // Connections held back by a gated server: accepted but not
        // started, so the client's WS handshake stays pending until
        // `open()` releases them. Lets tests control which of two
        // racing connect() calls completes first.
        var pendingStart: [NWConnection] = []
        var isOpen: Bool
        var acceptedTotal = 0
        var principal = Data(#"{"id":"test-owner","isAdministrator":true}"#.utf8)
        var modern = false
        var helloIDs: [String] = []
        var heldMethods: Set<String> = []
        var heldReplies: [HeldReply] = []
        var systemStatus = Data("{}".utf8)
        var hello: Data?
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
        var heldStatusCount: Int { state.withLock { $0.heldReplies.filter { $0.method == "host.status" }.count } }
        var heldSystemStatusCount: Int { state.withLock { $0.heldReplies.filter { $0.method == "system.status" }.count } }

        func holdHostStatus() { hold("host.status") }
        func holdSystemStatus() { hold("system.status") }
        func holdNewConnections() { state.withLock { $0.isOpen = false } }
        private func hold(_ method: String) { state.withLock { _ = $0.heldMethods.insert(method) } }

        func releaseHostStatus() { release("host.status") }
        func releaseSystemStatus() { release("system.status") }
        private func release(_ method: String) {
            let replies = state.withLock { state in
                state.heldMethods.remove(method)
                let replies = state.heldReplies.filter { $0.method == method }
                state.heldReplies.removeAll { $0.method == method }
                return replies
            }
            for reply in replies { send(reply.data, on: reply.connection) }
        }

        func emitRemoval(of principal: String) throws {
            let removalRevision = 10
            let data = try JSONSerialization.data(withJSONObject: [
                "jsonrpc": "2.0", "method": "events.event",
                "params": ["event": ["type": "host:members-changed", "data": ["revision": removalRevision, "principalId": principal, "action": "removed"]]]
            ])
            for connection in state.withLock({ $0.accepted }) { send(data, on: connection) }
        }

        func setPrincipal(_ principal: [String: Any], modern: Bool = true) {
            guard let data = try? JSONSerialization.data(withJSONObject: principal) else { return }
            state.withLock { $0.principal = data; $0.modern = modern }
        }

        func setSystemStatus(_ status: [String: Any]) throws {
            let data = try JSONSerialization.data(withJSONObject: status)
            state.withLock { $0.systemStatus = data }
        }

        func setHello(_ hello: [String: Any]) throws {
            let data = try JSONSerialization.data(withJSONObject: hello)
            state.withLock { $0.hello = data }
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

        static func start(gated: Bool = false, tlsIdentity: SecIdentity? = nil) async throws -> LoopbackWebSocketServer {
            let parameters: NWParameters
            if let tlsIdentity {
                let options = NWProtocolTLS.Options()
                let identity = try #require(sec_identity_create(tlsIdentity))
                sec_protocol_options_set_local_identity(options.securityProtocolOptions, identity)
                parameters = NWParameters(tls: options)
            } else {
                parameters = .tcp
            }
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
            let method = json["method"] as? String
            let clientID = (json["params"] as? [String: Any])?["clientId"] as? String
            let snapshot = state.withLock { state in
                if method == "client.hello", let clientID {
                    state.helloIDs.append(clientID)
                }
                return (state.principal, state.modern, state.systemStatus, state.hello)
            }
            if method == "principal.me" { return (try? JSONSerialization.jsonObject(with: snapshot.0)) as? [String: Any] ?? [:] }
            if method == "system.status" { return (try? JSONSerialization.jsonObject(with: snapshot.2)) as? [String: Any] ?? [:] }
            if method == "client.hello", let hello = snapshot.3 {
                return (try? JSONSerialization.jsonObject(with: hello)) as? [String: Any] ?? [:]
            }
            return ["server": ["protocolVersion": ProtocolFixtures.currentProtocolVersion, "capabilities": snapshot.1 ? ["hostMembership": 1] : [String: Int]()]]
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
                        let method = json["method"] as? String ?? ""
                        let held = state.withLock { state in
                            guard state.heldMethods.contains(method) else { return false }
                            state.heldReplies.append(HeldReply(connection: connection, data: payload, method: method))
                            return true
                        }
                        if !held { send(payload, on: connection) }
                    }
                }
                receiveNext(on: connection)
            }
        }

        private func send(_ data: Data, on connection: NWConnection) {
            let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
            let context = NWConnection.ContentContext(identifier: "response", metadata: [metadata])
            connection.send(content: data, contentContext: context, completion: .idempotent)
        }
    }
}
