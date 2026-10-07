import SwiftUI

/// The compact Assistant keeps its sheet and actions while its thread list loads.
struct AssistantStateContent: View {
    let isLoading: Bool
    let canCreateConversation: Bool
    let onCreateConversation: () -> Void
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast

    private typealias Design = Constants.Conversation.Design

    var body: some View {
        ScrollView {
            VStack(spacing: Design.sectionSpacing) {
                if isLoading {
                    ProgressView {
                        Text("Loading Assistant…")
                            .interFont(Constants.Typography.bodyS)
                            .foregroundStyle(Design.Palette.secondaryForeground(for: colorScheme, contrast: contrast))
                    }
                    .tint(Design.Palette.foreground(for: colorScheme))
                    .accessibilityIdentifier("assistant.loading")
                } else {
                    AssistantEmptyState(canCreateConversation: canCreateConversation, onCreateConversation: onCreateConversation)
                }
            }
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .padding(Design.horizontalInset)
            .frame(maxWidth: .infinity)
        }
        .defaultScrollAnchor(.center, for: .alignment)
        .scrollBounceBehavior(.basedOnSize)
        .foregroundStyle(Design.Palette.foreground(for: colorScheme))
        .background(Design.Palette.background(for: colorScheme))
    }
}
