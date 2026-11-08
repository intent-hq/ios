import SwiftUI

/// Shown above a note whose body is only a prefix: the daemon cut a note too
/// large for one read and the rest could not be loaded (PROTOCOL §5.2
/// "Bounded note and comment reads"). Offers a retry of the whole read.
struct NoteTruncationNotice: View {
    let shownBytes: Int
    let totalBytes: Int?
    let onRetry: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: Constants.Notes.Detail.truncationNoticeSpacing) {
            Label {
                Text(Self.message(shownBytes: shownBytes, totalBytes: totalBytes))
                    .interFont(Constants.Typography.bodyS)
                    .foregroundStyle(Theme.foreground(for: colorScheme))
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "scissors")
                    .foregroundStyle(Theme.mutedForeground(for: colorScheme))
                    .accessibilityHidden(true)
            }
            Button("Load the rest", action: onRetry)
                .interFont(Constants.Typography.bodyS)
                .frame(minHeight: Constants.Accessibility.minimumTapTarget)
                .accessibilityIdentifier("note-truncation-retry")
        }
        .padding(Constants.Notes.Detail.truncationNoticePadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.muted(for: colorScheme))
        .clipShape(RoundedRectangle(cornerRadius: Constants.Notes.Detail.truncationNoticeCornerRadius))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("note-truncation-notice")
    }

    /// "This note is only partly loaded. Showing the first 469 KB of 1.2 MB."
    static func message(shownBytes: Int, totalBytes: Int?) -> String {
        let shown = ByteCountFormatter.string(fromByteCount: Int64(shownBytes), countStyle: .file)
        guard let totalBytes, totalBytes > shownBytes else {
            return "This note is only partly loaded. Showing the first \(shown)."
        }
        let total = ByteCountFormatter.string(fromByteCount: Int64(totalBytes), countStyle: .file)
        return "This note is only partly loaded. Showing the first \(shown) of \(total)."
    }
}
