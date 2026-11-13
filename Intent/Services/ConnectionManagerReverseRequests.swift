import Foundation

extension ConnectionManager {
    func advertiseBrowserNavigation() {
        guard browserNavigationHandler != nil, let currentSocket = socket, let principal = currentPrincipal else { return }
        let generation = connectionGeneration
        Task { [weak self] in
            guard let self, connectionGeneration == generation, socket === currentSocket, currentPrincipal == principal else { return }
            _ = try? await request("client.hello", params: PairingClientIdentity.parameters(browserNavigation: true))
        }
    }

    /// Reverse IDs are opaque (the daemon uses strings); inspect method before
    /// matching ordinary numeric response IDs. Always reply on the same socket.
    func handleReverseRequest(id: Any, method: String, params: Any) {
        guard let currentSocket = socket else { return }
        let generation = connectionGeneration
        let principal = currentPrincipal
        Task { [weak self] in
            guard let self, connectionGeneration == generation, socket === currentSocket else { return }
            var reply: [String: Any] = ["jsonrpc": "2.0", "id": id]
            if method == "browser.exec", let handler = browserNavigationHandler,
               connectionState == .connected, let principal, currentPrincipal == principal,
               let params = params as? [String: Any] {
                reply["result"] = await handler(params)
            } else {
                let methodNotFound = -32_601
                reply["error"] = ["code": methodNotFound, "message": "This client cannot handle \(method)."]
            }
            guard connectionGeneration == generation, socket === currentSocket,
                  currentPrincipal == principal else { return }
            do {
                let data = try JSONSerialization.data(withJSONObject: reply)
                guard let text = String(data: data, encoding: .utf8) else { return }
                try await currentSocket.send(text)
            } catch {
                // Socket recovery owns transport failures. Never replay a reverse
                // request or its response on a replacement connection.
            }
        }
    }
}
