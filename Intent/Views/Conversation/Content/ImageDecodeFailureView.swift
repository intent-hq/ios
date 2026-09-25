import SwiftUI

/// Decode-failure fallback shared by inline images and attachment thumbnails.
struct ImageDecodeFailureView: View {
    @Environment(\.colorScheme) var colorScheme

    var body: some View {
        HStack(spacing: Constants.Conversation.ImagePlaceholder.failureLabelSpacing) {
            Image(systemName: "photo")
                .accessibilityHidden(true)
            Text("Image")
                .interFont(Constants.Typography.subtextXXS)
        }
        .font(.caption)
        .foregroundStyle(Theme.mutedForeground(for: colorScheme))
    }
}
