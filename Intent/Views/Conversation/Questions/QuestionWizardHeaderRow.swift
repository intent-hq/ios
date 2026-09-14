import SwiftUI

struct QuestionWizardHeaderRow: View {
    let questionCount: Int
    let index: Int
    let isMulti: Bool
    let showsDismiss: Bool
    let dismissed: Bool
    let onIgnore: () -> Void
    let onDismiss: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast

    private var multiStep: Bool { questionCount > 1 }

    var body: some View {
        HStack(spacing: Constants.Conversation.QuestionWizard.controlSpacing) {
            Image(systemName: "questionmark.circle")
                .font(.caption)
                .foregroundStyle(Theme.primary(for: colorScheme))
                .accessibilityHidden(true)
            Text("Questions")
                .font(.caption.weight(.medium))
                .foregroundStyle(Theme.foreground(for: colorScheme))
            if multiStep {
                Text("\(index + 1) of \(questionCount)")
                    .font(.caption)
                    .foregroundStyle(Theme.mutedForeground(for: colorScheme))
                HStack(spacing: 4) {
                    ForEach(0..<questionCount, id: \.self) { i in
                        RoundedRectangle(
                            cornerRadius: Constants.Conversation.QuestionWizard.progressSegmentCornerRadius
                        )
                        .fill(segmentColor(i))
                        .frame(
                            width: Constants.Conversation.QuestionWizard.progressSegmentWidth,
                            height: Constants.Conversation.QuestionWizard.progressSegmentHeight
                        )
                    }
                }
            }
            if isMulti {
                Text("Select all that apply")
                    .font(.caption)
                    .foregroundStyle(Theme.mutedForeground(for: colorScheme))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Theme.muted(for: colorScheme).opacity(0.8)))
            }
            Spacer(minLength: 8)
            Button(action: onIgnore) {
                Text("Ignore")
                    .font(.caption)
                    .foregroundStyle(Theme.mutedForeground(for: colorScheme))
                    .frame(
                        minWidth: Constants.Accessibility.minimumTapTarget,
                        minHeight: Constants.Accessibility.minimumTapTarget
                    )
            }
            .buttonStyle(.plain)
            if showsDismiss {
                QuestionWizardDismissButton(dismissed: dismissed, action: onDismiss)
            }
        }
        .padding(.horizontal, Constants.Conversation.QuestionWizard.contentHorizontalPadding)
        .padding(.top, 10)
    }

    private func segmentColor(_ segment: Int) -> Color {
        if segment < index {
            return Theme.primary(for: colorScheme).opacity(
                colorSchemeContrast == .increased ? 0.7 : 0.4
            )
        }
        if segment == index { return Theme.primary(for: colorScheme) }
        return Theme.mutedForeground(
            for: colorScheme,
            contrast: colorSchemeContrast
        )
            .opacity(colorSchemeContrast == .increased ? 0.55 : 0.25)
    }
}
