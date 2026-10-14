import SwiftUI

struct ConversationEmptyView: View {
    let viewModel: ConversationViewModel
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast

    private typealias Layout = Constants.Conversation.Column.Empty

    private var secondaryForeground: Color {
        if viewModel.workspaceId == Workspace.chiefWorkspaceId {
            return WorkspaceDetailStyle.secondary(for: colorScheme, contrast: contrast)
        }
        return Theme.mutedForeground(for: colorScheme)
    }

    var body: some View {
        if let name = viewModel.specialistName {
            VStack(spacing: Layout.contentSpacing) {
                Text(name)
                    .interFont(Constants.Typography.bodyM)
                    .foregroundStyle(Theme.foreground(for: colorScheme))
                if let description = viewModel.specialistDescription {
                    Text(description)
                        .interFont(Constants.Typography.bodyXS)
                        .foregroundStyle(secondaryForeground)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, Layout.descriptionHorizontalPadding)
                }
                if let displayName = viewModel.currentModelDisplayName {
                    Text("Using \(displayName)")
                        .interFont(Constants.Typography.subtextXXS)
                        .foregroundStyle(secondaryForeground.opacity(Layout.modelCaptionOpacity))
                        .padding(.top, Layout.modelCaptionTopPadding)
                }
            }
        } else {
            Color.clear
        }
    }
}
