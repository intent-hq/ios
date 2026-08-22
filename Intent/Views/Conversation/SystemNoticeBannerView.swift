import SwiftUI

/// Generic muted banner for system-role rows that are not classified
/// attention notices — e.g. `meta.kind = "interruption"` restart notices or
/// unknown future kinds — so they still render instead of disappearing.
/// FE parity: InterruptionNotice.svelte (ChatMessage.svelte system-branch
/// fallback).
struct SystemNoticeBannerView: View {
    /// The system message text; empty falls back to the default restart notice.
    let message: String

    static let defaultMessage = "This conversation was interrupted because intentd restarted."

    private var displayText: String {
        message.isEmpty ? Self.defaultMessage : message
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.subheadline)
                .foregroundStyle(.orange)
                .padding(.top, 1)

            Text(displayText)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.orange)
                .textSelection(.enabled)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.orange.opacity(0.3), lineWidth: 1)
        )
    }
}
