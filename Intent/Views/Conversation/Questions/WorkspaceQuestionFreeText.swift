import SwiftUI

/// Lets the native field lay out its prompt, caret, and multiline answer together.
struct WorkspaceQuestionFreeText: View {
    @Binding var text: String
    @Binding var focused: Bool
    let isLast: Bool
    let onSubmit: () -> Void
    let onTextChange: () -> Void
    var onPhotos: () -> Void = {}
    var onFiles: () -> Void = {}
    var onPasteImages: (() -> Void)?
    var photosEnabled = true

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast
    @State private var editorHeight = Constants.Conversation.Design.minimumTapTarget

    private typealias Design = Constants.Conversation.Design

    private static let lineFragmentPadding: CGFloat = 5

    private var editorInset: CGFloat { Constants.Conversation.Composer.textContainerInset + Self.lineFragmentPadding }

    var body: some View {
        HStack(spacing: Design.Question.buttonSpacing) {
            editor
            WorkspaceAttachmentMenu(onPhotos: onPhotos, onFiles: onFiles, photosEnabled: photosEnabled)
                .accessibilityIdentifier("question.attachment")
            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                focusButton
            } else {
                submitButton
            }
        }
        .padding(.leading, Design.Composer.leadingPadding - editorInset)
        .padding(.trailing, Design.Composer.activeTrailingPadding)
        .padding(.vertical, (Design.Composer.minimumHeight - Design.minimumTapTarget) / 2)
        .frame(minHeight: Design.Composer.minimumHeight)
        .background(Design.Palette.surface(for: colorScheme), in: .rect(cornerRadius: Design.cornerRadius))
        .onChange(of: text) { _, _ in onTextChange() }
    }

    private var editor: some View {
        ZStack(alignment: .leading) {
            SubmittableTextView(
                text: $text,
                isFocused: $focused,
                onSubmit: onSubmit,
                onPasteImages: onPasteImages,
                onHeightChange: { height in
                    editorHeight = QuestionStepView.clampedFreeTextHeight(height, lineHeight: QuestionStepView.freeTextLineHeight)
                },
                accessibilityLabel: String(localized: "Type your own answer…"),
                textColor: UIColor(Design.Palette.foreground(for: colorScheme))
            )
            .frame(height: max(Design.minimumTapTarget, editorHeight))
            .accessibilityIdentifier("question.freeText")
            if text.isEmpty {
                Text("Message")
                    .interFont(Constants.Typography.bodyS)
                    .foregroundStyle(Design.Palette.placeholderForeground(for: colorScheme, contrast: contrast))
                    .padding(.horizontal, editorInset)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
    }

    private var submitButton: some View {
        Button(action: onSubmit) {
            Image(.arrowRight)
                .resizable()
                .scaledToFit()
                .frame(width: Design.iconSize, height: Design.iconSize)
                .accessibilityHidden(true)
        }
        .buttonStyle(WorkspaceQuestionButtonStyle(primary: true))
        .accessibilityLabel(isLast ? "Send" : "Next")
        .accessibilityIdentifier("question.freeText.submit")
    }

    private var focusButton: some View {
        Button { focused = true } label: {
            Image(.addIcon)
                .resizable()
                .scaledToFit()
                .frame(width: Design.iconSize, height: Design.iconSize)
                .foregroundStyle(Design.Palette.placeholderForeground(for: colorScheme, contrast: contrast))
                .frame(width: Design.minimumTapTarget, height: Design.minimumTapTarget)
                .contentShape(.rect)
        }
        .buttonStyle(IntentContentButtonStyle())
        .accessibilityLabel("Write your own answer")
    }
}
