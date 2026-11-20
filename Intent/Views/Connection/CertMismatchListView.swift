import SwiftUI

struct CertMismatchListView: View {
    private typealias Layout = Constants.CertMismatch

    @Environment(\.colorScheme) var colorScheme
    let mismatches: [HostCertMismatch]
    var warningForeground: Color = .orange

    var body: some View {
        VStack(alignment: .leading, spacing: Layout.contentSpacing) {
            Label {
                Text("Certificate mismatch")
                    .interFont(Constants.Typography.subtextXXS.withFace(.semibold))
            } icon: {
                Image(systemName: "exclamationmark.shield")
                    .font(.caption.weight(.semibold))
            }
            .foregroundStyle(warningForeground)

            ForEach(mismatches, id: \.host) { mismatch in
                VStack(alignment: .leading, spacing: Layout.hostSpacing) {
                    Text(mismatch.host)
                        .interFont(Constants.Typography.subtextXXS.withFace(.medium))
                        .foregroundStyle(Theme.foreground(for: colorScheme))
                    Text(Self.displayFingerprint(mismatch.fingerprint))
                        .font(.caption2.monospaced())
                        .foregroundStyle(Theme.mutedForeground(for: colorScheme))
                        .lineLimit(1)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, Layout.verticalPadding)
        .padding(.horizontal, Layout.horizontalPadding)
        .background(Color.orange.opacity(Layout.backgroundOpacity))
        .clipShape(RoundedRectangle(cornerRadius: Layout.cornerRadius))
    }

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
                + "ab:cd:ef:01:23:45:67:89:ab:cd:ef:01:23:45:67:89"
        ),
        HostCertMismatch(host: "mac.local", fingerprint: "ee:ff:00:11")
    ])
    .padding()
}
