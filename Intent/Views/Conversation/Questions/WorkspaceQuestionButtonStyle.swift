import SwiftUI

/// Question actions use the workspace palette without restyling shared buttons.
struct WorkspaceQuestionButtonStyle: ButtonStyle {
    var primary = false
    var fillsWidth = false

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.isEnabled) private var isEnabled

    private typealias Design = Constants.Conversation.Design
    private typealias Layout = Constants.Conversation.QuestionWizard.Workspace

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .interFont(Constants.Typography.bodyXSEmphasized)
            .tracking(Design.Typography.smallTracking)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .foregroundStyle(primary ? Design.Palette.onAccent : Design.Palette.foreground(for: colorScheme))
            .padding(.horizontal, Design.Question.buttonHorizontalPadding)
            .padding(.vertical, Design.Question.buttonSpacing)
            .frame(maxWidth: fillsWidth ? .infinity : nil, minHeight: Design.minimumTapTarget)
            .background(primary ? Design.Palette.accent : Design.Palette.raisedSurface(for: colorScheme))
            .clipShape(.capsule)
            .contentShape(.rect)
            .opacity(isEnabled ? (configuration.isPressed ? Layout.pressedOpacity : 1) : Layout.disabledOpacity)
    }
}
