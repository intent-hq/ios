import Foundation

enum PairingFlow {
    enum FingerprintResolution: Equatable {
        case failed(message: String)
        case needsUserConfirmation(String)
        case pinned(String)
    }

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
            PairingDiagnostics.phase(.save, error is CancellationError ? .cancelled : .failed, store: diagnostics)
            throw error
        }
    }
}
