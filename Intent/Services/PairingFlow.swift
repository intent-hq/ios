import Foundation

/// Shared pairing-connection flow for QR scans (QRScannerView) and
/// `intent://pair` deep links (DeepLinkPairingView). Pairing connections are
/// always pinned over wss: a payload fingerprint is pinned directly, a
/// missing fingerprint is resolved by probing the server certificate and
/// asking the user to trust it, and a failed probe aborts — there is never a
/// plain-ws fallback.
enum PairingFlow {
    /// How to pin the connection for a parsed pairing payload.
    enum FingerprintResolution: Equatable {
        /// The payload carried a fingerprint — connect pinned immediately.
        case pinned(String)
        /// The payload carried no fingerprint: the server certificate was
        /// probed; the user must confirm trust before connecting pinned.
        case needsUserConfirmation(String)
        /// No payload fingerprint and the probe found no certificate — abort.
        case failed(message: String)
    }

    /// Resolve the certificate fingerprint to pin for a payload. `probe` is
    /// injectable for tests; the default performs the real TLS probe across
    /// the payload's hosts.
    static func resolveFingerprint(
        for payload: PairingPayload,
        probe: ([String], Int) async -> String? = { hosts, port in
            await CertFingerprintProbe.probeFirst(hosts: hosts, port: port)
        }
    ) async -> FingerprintResolution {
        if let fingerprint = payload.certFingerprint {
            return .pinned(fingerprint)
        }
        let probed = await probe(payload.hosts, payload.port)
        switch CertFingerprintProbe.outcome(forFingerprint: probed) {
        case .confirmFingerprint(let fingerprint):
            return .needsUserConfirmation(fingerprint)
        case .abort(let message):
            return .failed(message: message)
        }
    }

    /// Connect over wss with the fingerprint pinned and persist the pairing
    /// via ConnectionPairing.finalize. Every pairing path goes through here
    /// with a non-nil fingerprint (from the payload or the trust-confirmed
    /// probe), so pairing can never fall back to plain ws://.
    /// `connectionManager` is the window session's own connection (window
    /// model v2: there is no default session), so the pairing dials the
    /// connection the presenting window will keep using.
    static func connect(
        payload: PairingPayload,
        certFingerprint: String,
        connectionManager: any SessionConnectionManaging,
        persistence: PersistenceManager = .shared
    ) async throws -> StoredConnection {
        try await connectionManager.connect(
            hosts: payload.hosts,
            port: payload.port,
            token: payload.token,
            certFingerprint: certFingerprint,
            tcAddress: payload.tcAddress
        )
        // A cancelled pairing (deep-link sheet dismissed mid-flight) must
        // not be persisted after the connect happens to complete first —
        // and the just-established authenticated socket must not be left
        // dangling with no UI reflecting it.
        if Task.isCancelled {
            connectionManager.disconnect()
            throw CancellationError()
        }
        let server = PairedServer(
            hosts: payload.hosts,
            port: payload.port,
            name: "Intent",
            pairedAt: Date(),
            certFingerprint: certFingerprint,
            tcAddress: payload.tcAddress
        )
        do {
            return try await ConnectionPairing.finalize(
                server: server,
                token: payload.token,
                connection: connectionManager,
                persistence: persistence
            )
        } catch {
            // The authenticated socket belongs to this failed pairing attempt;
            // do not leave it live when no saved connection can own it.
            connectionManager.disconnect()
            throw error
        }
    }
}
