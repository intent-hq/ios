import Foundation

extension WebSocketConnection {
    /// Runs before adoption/message pumping so a failed candidate cannot
    /// replace a working connection. Admission messages never enter logs.
    func admittedHandshake(helloRequest: Data) async throws -> ConnectionHandshake {
        let hello = try await admissionRequest(helloRequest, id: -1)
        let request = Data(#"{"jsonrpc":"2.0","id":-2,"method":"principal.me"}"#.utf8)
        let principal = try await admissionRequest(request, id: -2)
        return try ConnectionHandshake(principal: ConnectionPrincipal.parse(principal, hello: hello), capabilities: ConnectionCapabilities(hello: hello))
    }

    private func admissionRequest(_ data: Data, id: Int) async throws -> Any {
        guard let text = String(data: data, encoding: .utf8) else { throw ConnectionPrincipal.AdmissionError.incompatible }
        try await send(text)
        while !Task.isCancelled {
            let message = try await receive()
            guard case .string(let text) = message,
                  let data = text.data(using: .utf8),
                  let row = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  ConnectionPrincipal.number(row["id"]) == Double(id) else { continue }
            if let error = row["error"] as? [String: Any] {
                let code = (error["data"] as? [String: Any])?["code"] as? String ?? ""
                throw NSError(domain: "WebSocket", code: (error["code"] as? Int) ?? -1, userInfo: [
                    NSLocalizedDescriptionKey: "The host could not confirm access. Please pair again if access was revoked.",
                    NSError.intentErrorDataCodeKey: code
                ])
            }
            guard let result = row["result"] else { throw ConnectionPrincipal.AdmissionError.incompatible }
            return result
        }
        throw CancellationError()
    }
}

extension ConnectionManager {
    func admit(_ winner: RacedConnection) async throws -> ConnectionHandshake {
        let data = try JSONSerialization.data(withJSONObject: [
            "jsonrpc": "2.0", "id": -1, "method": "client.hello", "params": PairingClientIdentity.parameters()
        ])
        let timeoutSeconds = 10
        do {
            return try await withTaskCancellationHandler {
                try await withThrowingTaskGroup(of: ConnectionHandshake.self) { group in
                    group.addTask { try await winner.socket.admittedHandshake(helloRequest: data) }
                    group.addTask {
                        try await Task.sleep(for: .seconds(timeoutSeconds))
                        await winner.disconnect()
                        throw ConnectionPrincipal.AdmissionError.timedOut
                    }
                    defer { group.cancelAll() }
                    guard let result = try await group.next() else { throw CancellationError() }
                    return result
                }
            } onCancel: {
                Task { await winner.disconnect() }
            }
        } catch {
            await winner.disconnect()
            throw error
        }
    }
}
