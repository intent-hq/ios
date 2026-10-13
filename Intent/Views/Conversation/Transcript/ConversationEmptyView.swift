import SwiftUI

struct ConversationEmptyView: View {
    let viewModel: ConversationViewModel
    @Environment(\.colorScheme) private var colorScheme

    private typealias Layout = Constants.Conversation.Column.Empty

    var body: some View {
        if let name = viewModel.specialistName {
            VStack(spacing: Layout.contentSpacing) {
                Text(name)
                    .interFont(Constants.Typography.bodyM)
                    .foregroundStyle(Theme.foreground(for: colorScheme))
                if let description = viewModel.specialistDescription {
                    Text(description)
                        .interFont(Constants.Typography.bodyXS)
                        .foregroundStyle(Theme.mutedForeground(for: colorScheme))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, Layout.descriptionHorizontalPadding)
                }
                if let displayName = viewModel.currentModelDisplayName {
                    Text("Using \(displayName)")
                        .interFont(Constants.Typography.subtextXXS)
                        .foregroundStyle(Theme.mutedForeground(for: colorScheme).opacity(Layout.modelCaptionOpacity))
                        .padding(.top, Layout.modelCaptionTopPadding)
                }
            }
        } else {
            Color.clear
        }
    }
}
