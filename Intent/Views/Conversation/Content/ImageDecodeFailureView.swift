import SwiftUI

/// Decode-failure fallback shared by inline images and attachment thumbnails.
struct ImageDecodeFailureView: View {
    @Environment(\.colorScheme) var colorScheme
    @ScaledMetric(relativeTo: .caption) private var iconSide: CGFloat = 12

    var body: some View {
        HStack(spacing: Constants.Conversation.ImagePlaceholder.failureLabelSpacing) {
            Image(.image)
                .resizable()
                .scaledToFit()
                .frame(width: iconSide, height: iconSide)
                .accessibilityHidden(true)
            Text("Image")
                .interFont(Constants.Typography.subtextXXS)
        }
        .font(.caption)
        .foregroundStyle(Theme.mutedForeground(for: colorScheme))
    }
}
