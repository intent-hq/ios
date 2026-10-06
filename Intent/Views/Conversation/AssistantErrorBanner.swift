import SwiftUI

struct AssistantErrorBanner: View {
    let error: String
    let onRetry: () -> Void
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast

    private typealias Design = Constants.Conversation.Design

    var body: some View {
        VStack(alignment: .leading, spacing: Design.Transcript.toolRowSpacing) {
            Text(error)
                .interFont(Constants.Typography.bodyS)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("assistant.error")
            Button(action: onRetry) {
                Text("Retry").interFont(Constants.Typography.bodySEmphasized)
            }
            .buttonStyle(IntentButtonStyle(variant: .secondary))
            .accessibilityIdentifier("assistant.retry")
        }
        .foregroundStyle(Design.Palette.foreground(for: colorScheme))
        .padding(Design.Transcript.bubblePadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Design.Palette.surface(for: colorScheme), in: .rect(cornerRadius: Design.cornerRadius))
        .overlay {
            RoundedRectangle(cornerRadius: Design.cornerRadius)
                .strokeBorder(Design.Palette.border(for: colorScheme, contrast: contrast))
        }
        .padding(.horizontal, Design.horizontalInset)
        .padding(.vertical, Design.Header.verticalPadding)
        .background(Design.Palette.background(for: colorScheme))
    }
}
