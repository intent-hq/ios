import Combine
import CryptoKit
import Foundation
import Network

struct DiscoveredServer: Identifiable, Equatable {
    let id: String  // endpoint description
    let name: String
    let host: String?
    let port: Int?
    let certFingerprint: String?
}

@MainActor
class BonjourBrowser: ObservableObject {
    @Published var servers: [DiscoveredServer] = []
    @Published var isSearching = false

    private var browser: NWBrowser?

    func startBrowsing() {
        isSearching = true
        servers = []

        let params = NWParameters()
        params.includePeerToPeer = true

        browser = NWBrowser(for: .bonjour(type: "_intent-ws._tcp", domain: nil), using: params)

        browser?.browseResultsChangedHandler = { [weak self] results, _ in
            Task { @MainActor in
                print("[BonjourBrowser] Browse results changed: \(results.count) results")
                self?.servers = results.compactMap { result in
                    switch result.endpoint {
                    case .service(let name, _, _, _):
                        // Extract cert fingerprint from TXT record metadata
                        // Key is "fp" (short for fingerprint), with fallbacks for legacy keys
                        var fingerprint: String?
                        if case .bonjour(let txtRecord) = result.metadata {
                            let dict = txtRecord.dictionary
                            print("[BonjourBrowser] TXT record for \(name): \(dict)")
                            fingerprint = dict["fp"] ?? dict["certFingerprint"] ?? dict["certfingerprint"]
                        } else {
                            print("[BonjourBrowser] No TXT record metadata for \(result.endpoint)")
                        }
                        return DiscoveredServer(
                            id: "\(result.endpoint)",
                            name: name,
                            host: nil,
                            port: nil,
                            certFingerprint: fingerprint
                        )
                    default:
                        return nil
                    }
                }
            }
        }

        browser?.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                switch state {
                case .ready:
                    self?.isSearching = true
                case .failed, .cancelled:
                    self?.isSearching = false
                default:
                    break
                }
            }
        }

        browser?.start(queue: .main)
    }

    func stopBrowsing() {
        browser?.cancel()
        browser = nil
        isSearching = false
    }

    func resolve(_ server: DiscoveredServer) async -> (host: String, port: Int, certFingerprint: String?)? {
        guard let endpoint = findEndpoint(for: server) else {
            print("[BonjourBrowser] Could not find endpoint for server: \(server.id)")
            print("[BonjourBrowser] Available endpoints: \(browser?.browseResults.map { "\($0.endpoint)" } ?? [])")
            return nil
        }

        print("[BonjourBrowser] Resolving endpoint: \(endpoint)")

        let resolved: (host: String, port: Int)? = await withCheckedContinuation { continuation in
            let connection = NWConnection(to: endpoint, using: .tcp)
            var resumed = false
            connection.stateUpdateHandler = { state in
                print("[BonjourBrowser] Connection state: \(state)")
                switch state {
                case .ready:
                    if !resumed,
                       let innerEndpoint = connection.currentPath?.remoteEndpoint,
                       case .hostPort(let host, let port) = innerEndpoint {
                        resumed = true
                        connection.cancel()
                        continuation.resume(returning: (host: "\(host)", port: Int(port.rawValue)))
                    } else if !resumed {
                        resumed = true
                        connection.cancel()
                        continuation.resume(returning: nil)
                    }
                case .failed, .cancelled:
                    if !resumed {
                        resumed = true
                        continuation.resume(returning: nil)
                    }
                default:
                    break
                }
            }
            connection.start(queue: .global())

            // Timeout after 5 seconds
            DispatchQueue.global().asyncAfter(deadline: .now() + 5) {
                if !resumed {
                    print("[BonjourBrowser] Resolution timed out for \(server.name)")
                    resumed = true
                    connection.cancel()
                    continuation.resume(returning: nil)
                }
            }
        }

        guard let resolved = resolved else { return nil }

        // Fetch cert fingerprint directly from the server via TLS handshake
        let fingerprint = await fetchCertFingerprint(host: resolved.host, port: resolved.port)
        return (host: resolved.host, port: resolved.port, certFingerprint: fingerprint ?? server.certFingerprint)
    }

    /// Fetch the TLS certificate fingerprint by connecting to the server's health endpoint.
    private nonisolated func fetchCertFingerprint(host: String, port: Int) async -> String? {
        let delegate = CertFingerprintDelegate()
        let session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }

        guard let url = URL(string: "https://\(host):\(port)/health") else { return nil }

        do {
            let _ = try await session.data(from: url)
        } catch {
            // Connection may fail (self-signed cert) but we still capture the cert in the delegate
            print("[BonjourBrowser] Health check error (expected for self-signed): \(error.localizedDescription)")
        }

        return delegate.capturedFingerprint
    }

    private func findEndpoint(for server: DiscoveredServer) -> NWEndpoint? {
        browser?.browseResults.first { "\($0.endpoint)" == server.id }?.endpoint
    }
}

// MARK: - Certificate Fingerprint Capture Delegate

private class CertFingerprintDelegate: NSObject, URLSessionDelegate {
    var capturedFingerprint: String?

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let serverTrust = challenge.protectionSpace.serverTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }

        // Extract the server certificate using the deprecated-but-compatible API
        if SecTrustGetCertificateCount(serverTrust) > 0,
           let serverCert = SecTrustGetCertificateAtIndex(serverTrust, 0) {
            let certData = SecCertificateCopyData(serverCert) as Data
            // Compute SHA-256 fingerprint (lowercase hex with colons, matching CertPinningDelegate format)
            let hash = SHA256.hash(data: certData)
            capturedFingerprint = hash.map { String(format: "%02x", $0) }.joined(separator: ":")
            print("[BonjourBrowser] Captured cert fingerprint: \(capturedFingerprint!)")
        }

        // Accept the self-signed cert for this health check
        completionHandler(.useCredential, URLCredential(trust: serverTrust))
    }
}

