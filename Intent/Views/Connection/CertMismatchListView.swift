import SwiftUI

/// Passive per-host certificate-mismatch list: one row per host with the
/// fingerprint it actually presented. Rendered while connecting/reconnecting
/// (retries continue on the remaining hosts), on the cert-mismatch re-pair
/// screen (every mismatching host, not just the last one), and as a
/// non-blocking indicator in the connection details while connected via a
/// route that still has stale mismatching siblings. Purely informational —
/// no actions.
struct CertMismatchListView: View {
    @Environment(\.colorScheme) var colorScheme
    let mismatches: [HostCertMismatch]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Certificate mismatch", systemImage: "exclamationmark.shield")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.orange)

            ForEach(mismatches, id: \.host) { mismatch in
                VStack(alignment: .leading, spacing: 1) {
                    Text(mismatch.host)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(Theme.foreground(for: colorScheme))
                    Text(Self.displayFingerprint(mismatch.fingerprint))
                        .font(.caption2.monospaced())
                        .foregroundStyle(Theme.mutedForeground(for: colorScheme))
                        .lineLimit(1)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 10)
        .padding(.horizontal, 12)
        .background(Color.orange.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    /// Truncates a colon-separated SHA-256 fingerprint (32 bytes) to its
    /// leading bytes with an ellipsis so a row stays one line; short values
    /// (e.g. test fixtures) pass through unchanged.
    static func displayFingerprint(_ fingerprint: String, maxBytes: Int = 8) -> String {
        let parts = fingerprint.split(separator: ":")
        guard parts.count > maxBytes else { return fingerprint }
        return parts.prefix(maxBytes).joined(separator: ":") + "…"
    }
}

#Preview("Cert mismatches") {
    CertMismatchListView(mismatches: [
        HostCertMismatch(
            host: "192.168.1.42",
            fingerprint: "ab:cd:ef:01:23:45:67:89:ab:cd:ef:01:23:45:67:89:"
                + "ab:cd:ef:01:23:45:67:89:ab:cd:ef:01:23:45:67:89"),
        HostCertMismatch(host: "mac.local", fingerprint: "ee:ff:00:11"),
    ])
    .padding()
}
