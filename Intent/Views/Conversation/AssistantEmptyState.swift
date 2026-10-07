import SwiftUI

struct AssistantEmptyState: View {
    let canCreateConversation: Bool
    let onCreateConversation: () -> Void
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast

    private typealias Design = Constants.Conversation.Design

    var body: some View {
        VStack(spacing: Design.sectionSpacing) {
            Image(.intentDandelion)
                .resizable()
                .scaledToFit()
                .frame(width: Design.Header.controlSize, height: Design.Header.controlSize)
                .accessibilityHidden(true)
            Text("Assistant")
                .interFont(Constants.Typography.heading2)
                .accessibilityAddTraits(.isHeader)
            Text("Plan your work and get help across all your workspaces.")
                .interFont(Constants.Typography.bodyS)
                .foregroundStyle(Design.Palette.secondaryForeground(for: colorScheme, contrast: contrast))
            Button(action: onCreateConversation) {
                Text("Start a Conversation").interFont(Constants.Typography.bodySEmphasized)
            }
            .buttonStyle(IntentButtonStyle())
            .disabled(!canCreateConversation)
            .accessibilityIdentifier("assistant.startConversation")
        }
    }
}
