import Combine
import Foundation

extension ConnectionManager {
    /// Uses the winning route, including the existing Tailcat loopback forwarder.
    /// The auxiliary tunnel keeps bearer credentials out of browser content.
    func makeBrowserProxy() async throws -> any BrowserProxySession {
        guard connectionState == .connected, let currentSocket = socket,
              let host, let port, let token else { throw BrowserTunnelError.unavailable }
        let generation = connectionGeneration
        let tunnel = activeTunnel
        let fingerprint = certFingerprint
        // system.status exposes the same protocolVersion as client.hello,
        // without replacing the live RPC connection's client identity.
        let status = try await request("system.status") as? [String: Any]
        let version = status?["protocolVersion"] as? String
        guard connectionGeneration == generation, socket === currentSocket,
              connectionState == .connected else { throw BrowserTunnelError.closed }
        let browserSocket = try await WebSocketConnection.connect(
            host: tunnel == nil ? host : "127.0.0.1",
            port: tunnel?.localPort ?? port,
            token: token,
            certFingerprint: fingerprint,
            endpoint: .tunnel
        )
        guard !Task.isCancelled, connectionGeneration == generation,
              socket === currentSocket, connectionState == .connected else {
            await browserSocket.disconnect()
            try Task.checkCancellation()
            throw BrowserTunnelError.closed
        }
        let proxy = BrowserTunnelProxy(
            socket: browserSocket,
            supportsCredit: BrowserTunnelFrame.supportsCredit(protocolVersion: version),
            isCurrentConnection: { [weak self] in
                self?.connectionGeneration == generation && self?.socket === currentSocket
                    && self?.connectionState == .connected
            }
        )
        proxy.connectionObserver = connectionStatePublisher.sink { @Sendable [weak proxy, weak self] state in
            Task { @MainActor in
                if state != .connected || self?.connectionGeneration != generation {
                    await proxy?.close()
                }
            }
        }
        return proxy
    }
}
