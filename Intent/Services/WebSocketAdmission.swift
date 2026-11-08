import Foundation

extension WebSocketConnection {
    private static let startupRequestID = -3

    /// Bootstrap sockets stay outside the app's message pump. Even a ready
    /// snapshot retires this socket; only a fresh hello can admit a principal.
    func admittedHandshake(
        helloRequest: Data,
        onStartup: @escaping @Sendable (DaemonStartupState) async throws -> Void = { _ in }
    ) async throws -> ConnectionHandshake {
        let hello: Any
        do {
            hello = try await admissionRequest(helloRequest, id: -1)
        } catch let startup as DaemonStartupError {
            try await awaitStartup(startup, onUpdate: onStartup)
            throw DaemonStartupError.reconnect
        }
        let request = Data(#"{"jsonrpc":"2.0","id":-2,"method":"principal.me"}"#.utf8)
        let principal = try await admissionRequest(request, id: -2)
        return try ConnectionHandshake(principal: ConnectionPrincipal.parse(principal, hello: hello), capabilities: ConnectionCapabilities(hello: hello))
    }

    private func awaitStartup(
        _ rejection: DaemonStartupError,
        onUpdate: @Sendable (DaemonStartupState) async throws -> Void
    ) async throws {
        var snapshot: DaemonStartupStatus?
        switch rejection {
        case .notReady(let status): snapshot = status
        case .failed:
            try await onUpdate(.failed)
            throw DaemonStartupError.failed
        case .reconnect: return
        }
        while true {
            try Task.checkCancellation()
            if snapshot?.phase == .failed {
                try await onUpdate(.failed)
                throw DaemonStartupError.failed
            }
            try await onUpdate(.starting(snapshot))
            if snapshot?.phase == .ready { return }
            try await Task.sleep(for: .milliseconds(snapshot?.retryAfterMs ?? DaemonStartupStatus.minimumRetryMs))
            do {
                let request = Data(#"{"jsonrpc":"2.0","id":-3,"method":"system.startupStatus"}"#.utf8)
                snapshot = DaemonStartupStatus.parse(try await admissionRequest(request, id: Self.startupRequestID))
            } catch {
                try Task.checkCancellation()
                if case DaemonStartupError.failed = error {
                    try await onUpdate(.failed)
                    throw error
                }
                try await onUpdate(.unavailable)
                // Includes close-on-ready and failed/timed-out polling. No
                // cached progress remains current and no mutation is replayed.
                throw DaemonStartupError.reconnect
            }
        }
    }

    private func admissionRequest(_ data: Data, id: Int) async throws -> Any {
        let timeoutSeconds = 10
        let response = try await withThrowingTaskGroup(of: InboundJSONValue.self) { group in
            group.addTask { try await self.readAdmissionResponse(data, id: id) }
            group.addTask {
                try await Task.sleep(for: .seconds(timeoutSeconds))
                await self.disconnect()
                throw ConnectionPrincipal.AdmissionError.timedOut
            }
            defer { group.cancelAll() }
            guard let response = try await group.next() else { throw CancellationError() }
            return response
        }
        return response.value
    }

    private func readAdmissionResponse(_ data: Data, id: Int) async throws -> InboundJSONValue {
        guard let text = String(data: data, encoding: .utf8) else { throw ConnectionPrincipal.AdmissionError.incompatible }
        try await send(text)
        while !Task.isCancelled {
            let message = try await receive()
            guard case .string(let text) = message,
                  let data = text.data(using: .utf8),
                  let row = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  ConnectionPrincipal.number(row["id"]) == Double(id) else { continue }
            if let error = row["error"] as? [String: Any] {
                let details = error["data"] as? [String: Any]
                let startupErrorCode = -32_012
                if ConnectionPrincipal.number(error["code"]) == Double(startupErrorCode) {
                    if details?["code"] as? String == "daemon-startup-failed" { throw DaemonStartupError.failed }
                    throw DaemonStartupError.notReady(DaemonStartupStatus.parse(details?["startup"]))
                }
                throw NSError(domain: "WebSocket", code: (error["code"] as? Int) ?? -1, userInfo: [
                    NSLocalizedDescriptionKey: "The host could not confirm access. Please pair again if access was revoked.",
                    NSError.intentErrorDataCodeKey: details?["code"] as? String ?? ""
                ])
            }
            guard let result = row["result"] else { throw ConnectionPrincipal.AdmissionError.incompatible }
            return InboundJSONValue(value: result)
        }
        throw CancellationError()
    }
}

extension ConnectionManager {
    func admit(_ winner: RacedConnection) async throws -> ConnectionHandshake {
        let data = try JSONSerialization.data(withJSONObject: [
            "jsonrpc": "2.0", "id": -1, "method": "client.hello", "params": PairingClientIdentity.parameters()
        ])
        let attemptID = startupRun.id
        let generation = connectionGeneration
        return try await withTaskCancellationHandler {
            try await winner.socket.admittedHandshake(helloRequest: data) { [weak self] state in
                try await self?.receiveStartup(state, attemptID: attemptID, generation: generation)
            }
        } onCancel: {
            Task { await winner.disconnect() }
        }
    }
}
