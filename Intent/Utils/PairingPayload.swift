import Foundation

/// Parsed `intent://pair` pairing payload from a QR code.
///
/// Two dialects exist in the wild:
/// - Canonical daemon payload (`pairing.getInfo` / `intentd pair`, protocol §5):
///   `intent://pair?v=1&host=<ip[,ip...]>&port=<p>&fp=<sha256>&token=<t>`
/// - Legacy desktop-app payload (WebSocketApiSettings):
///   `intent://pair?token=...&host=...&port=...&path=/ws&certFingerprint=...`
///
/// `v=` and `path=` are tolerated and ignored.
struct PairingPayload: Equatable {
    let hosts: [String]
    let port: Int
    let token: String
    let certFingerprint: String?
    /// Tailcat tunnel address (`tc=`, the "tc..." connection token), appended
    /// by the daemon only when its tunnel is running. Optional and tolerated
    /// absent; empty values are normalized to nil.
    let tcAddress: String?

    /// Parse a scanned QR payload. Returns nil when the payload is not a
    /// well-formed `intent://pair` URI with token, host, and numeric port.
    static func parse(_ code: String) -> PairingPayload? {
        guard let components = URLComponents(string: code),
              components.scheme == "intent",
              components.host == "pair",
              let items = components.queryItems,
              let token = items.first(where: { $0.name == "token" })?.value,
              let hostStr = items.first(where: { $0.name == "host" })?.value,
              let portStr = items.first(where: { $0.name == "port" })?.value,
              let port = Int(portStr) else {
            return nil
        }

        let hosts = hostStr.split(separator: ",").map(String.init)
        guard !hosts.isEmpty else { return nil }

        // The first non-empty fingerprint wins, canonical `fp=` first (so an
        // empty `fp=` falls back to a non-empty legacy `certFingerprint=`).
        // Empty values are normalized to nil so callers take the cert-probe
        // path instead of pinning an empty string.
        let fingerprint = [
            items.first(where: { $0.name == "fp" })?.value,
            items.first(where: { $0.name == "certFingerprint" })?.value,
        ]
        .compactMap { $0 }
        .first(where: { !$0.isEmpty })

        let tcAddress = items.first(where: { $0.name == "tc" })?.value
            .flatMap { $0.isEmpty ? nil : $0 }

        return PairingPayload(
            hosts: hosts, port: port, token: token, certFingerprint: fingerprint,
            tcAddress: tcAddress)
    }
}
