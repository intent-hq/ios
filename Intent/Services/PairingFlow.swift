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
        /// No payload fingerprint and the probe failed — abort. The message
        /// names the stage the probe failed at (unreachable, timeout, TLS
        /// handshake, no certificate).
        case failed(message: String)
        /// The payload carried no fingerprint: the server certificate was
        /// probed; the user must confirm trust before connecting pinned.
        case needsUserConfirmation(String)
        /// The payload carried a fingerprint — connect pinned immediately.
        case pinned(String)
    }

    /// Resolve the certificate fingerprint to pin for a payload. `probe` is
    /// injectable for tests; the default performs the real TLS probe across
    /// the payload's hosts.
    static func resolveFingerprint(
        for payload: PairingPayload,
        diagnostics: DiagnosticStore = .shared,
        probe: ([String], Int) async -> CertFingerprintProbe.ProbeResult = { hosts, port in
            await CertFingerprintProbe.probeFirst(hosts: hosts, port: port)
        }
    ) async -> FingerprintResolution {
        PairingDiagnostics.phase(.input, .started, store: diagnostics)
        if let fingerprint = payload.certFingerprint {
            guard (try? InvitedSyncKey.fingerprint(fingerprint)) != nil else {
                return .failed(message: "The pairing link has an invalid server fingerprint. Ask for a new link.")
            }
            PairingDiagnostics.phase(.input, .succeeded, store: diagnostics)
            return .pinned(fingerprint)
        }
        PairingDiagnostics.phase(.probe, .started, store: diagnostics)
        let probed = await probe(payload.hosts, payload.port)
        PairingDiagnostics.probeResult(probed, store: diagnostics)
        switch CertFingerprintProbe.outcome(forProbe: probed) {
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
        persistence: PersistenceManager = .shared,
        diagnostics: DiagnosticStore = .shared
    ) async throws -> StoredConnection {
        let attemptID = UUID()
        var persisted = false
        defer { if !persisted { connectionManager.disconnectPairingAttempt(attemptID) } }
        PairingDiagnostics.phase(.connect, .started, store: diagnostics)
        do {
            try await PairingConnectionContext.$attemptID.withValue(attemptID) {
                try await DiagnosticConnectContext.$origin.withValue(.pairing) {
                    try await connectionManager.connect(
                        hosts: payload.hosts,
                        port: payload.port,
                        token: payload.token,
                        certFingerprint: certFingerprint,
                        tcAddress: payload.tcAddress
                    )
                }
            }
        } catch {
            PairingDiagnostics.phase(.connect, error is CancellationError || Task.isCancelled ? .cancelled : .failed, store: diagnostics)
            throw error
        }
        // A cancelled pairing (deep-link sheet dismissed mid-flight) must
        // not be persisted after the connect happens to complete first —
        // and the just-established authenticated socket must not be left
        // dangling with no UI reflecting it.
        if Task.isCancelled || connectionManager.pairingAttemptID != attemptID {
            PairingDiagnostics.phase(.connect, .cancelled, store: diagnostics)
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
            PairingDiagnostics.phase(.save, .started, store: diagnostics)
            let stored = try await ConnectionPairing.finalize(
                server: server,
                token: payload.token,
                connection: connectionManager,
                persistence: persistence
            )
            persisted = true
            PairingDiagnostics.phase(.save, .succeeded, store: diagnostics)
            return stored
        } catch {
            // The persistence task owns the save failure; this is phase context.
            PairingDiagnostics.phase(.save, error is CancellationError ? .cancelled : .failed, store: diagnostics)
            throw error
        }
    }
}
