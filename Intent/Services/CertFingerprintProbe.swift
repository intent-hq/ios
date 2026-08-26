import CryptoKit
import Foundation

/// Probes a server's TLS certificate fingerprint ahead of pairing, shared by
/// manual token entry and QR pairing payloads that carry no fingerprint.
/// Pairing connections must always be pinned: a missing fingerprint aborts
/// instead of falling back to plain WS.
enum CertFingerprintProbe {
    /// Decision for a completed TLS probe.
    enum Outcome: Equatable {
        case confirmFingerprint(String)
        case abort(message: String)
    }

    static let noCertErrorMessage =
        "Could not verify the server's TLS certificate. Check the host and port, make sure the desktop app is running, and try again."

    static func outcome(forFingerprint fingerprint: String?) -> Outcome {
        if let fingerprint, !fingerprint.isEmpty {
            return .confirmFingerprint(fingerprint)
        }
        return .abort(message: noCertErrorMessage)
    }

    /// Probe the server's TLS certificate fingerprint via an HTTPS health check.
    static func probe(host: String, port: Int) async -> String? {
        let delegate = CertProbeDelegate()
        let configuration = URLSessionConfiguration.ephemeral
        // Fail fast on unroutable hosts (default is 60s): a multi-host QR
        // payload probes hosts sequentially, so a hung host would otherwise
        // stall the pairing spinner for minutes. 4s matches the websocket
        // timeout ConnectionManager.raceHosts uses per host.
        configuration.timeoutIntervalForRequest = 4
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }

        guard let url = URL(string: "https://\(host):\(port)/health") else { return nil }

        do {
            let _ = try await session.data(from: url)
        } catch {
            // Connection may fail (self-signed cert) but we still capture the cert in the delegate
        }

        return delegate.capturedFingerprint
    }

    /// Probe hosts in order and return the first fingerprint found, or nil
    /// when no host yields a certificate.
    static func probeFirst(hosts: [String], port: Int) async -> String? {
        for host in hosts {
            if let fingerprint = await probe(host: host, port: port), !fingerprint.isEmpty {
                return fingerprint
            }
        }
        return nil
    }
}

// MARK: - Certificate Probe Delegate

private class CertProbeDelegate: NSObject, URLSessionDelegate {
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

        if SecTrustGetCertificateCount(serverTrust) > 0,
           let certChain = SecTrustCopyCertificateChain(serverTrust) as? [SecCertificate],
           let serverCert = certChain.first {
            let certData = SecCertificateCopyData(serverCert) as Data
            let hash = SHA256.hash(data: certData)
            capturedFingerprint = hash.map { String(format: "%02x", $0) }.joined(separator: ":")
        }

        // Accept the self-signed cert for this probe
        completionHandler(.useCredential, URLCredential(trust: serverTrust))
    }
}
