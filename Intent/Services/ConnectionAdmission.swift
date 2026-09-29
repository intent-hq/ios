import Foundation

/// The identity actually admitted on one socket. Reconnect-cache updates do
/// not change this receipt or attribute an old socket's revocation to a new token.
nonisolated struct ConnectionAdmission: Equatable, Sendable {
    let id: UUID
    let token: String
    let fingerprint: String?
    let principal: ConnectionPrincipal
}

/// A pairing owns its connection across automatic transport recovery, until
/// an explicit replacement connect or disconnect takes over. Socket admission
/// remains separate because every replacement socket must recheck authority.
nonisolated enum PairingConnectionContext {
    @TaskLocal static var attemptID: UUID?
}

extension SessionConnectionManaging {
    func pairingAdmission(token: String, fingerprint: String?) throws -> ConnectionAdmission {
        guard let admission, admission.token == token,
              admission.fingerprint == fingerprint,
              connectionState == .connected, admission.principal == currentPrincipal else {
            throw ConnectionPrincipal.AdmissionError.personChanged
        }
        return admission
    }

    func validatePairingAdmission(_ receipt: ConnectionAdmission) throws {
        guard connectionState == .connected, admission == receipt, currentPrincipal == receipt.principal else {
            throw ConnectionPrincipal.AdmissionError.personChanged
        }
    }

    func disconnectPairingAttempt(_ id: UUID) {
        guard pairingAttemptID == id else { return }
        disconnect()
    }
}
