import SwiftUI
import UIKit

struct QuestionStepView: View {
    let step: Int
    let question: Question
    @Binding var selectedIndices: [Int]
    @Binding var freeText: String
    let isMulti: Bool
    let contentHeight: CGFloat?
    let maximumHeight: CGFloat
    let onContentHeight: (Int, CGFloat) -> Void
    let onSelect: (Int) -> Void
    let onSubmit: () -> Void
    let onTextChange: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @ScaledMetric(relativeTo: .caption) private var checkboxSide =
        Constants.Conversation.QuestionWizard.checkboxSide
    @State private var freeTextFocused = false
    @State private var freeTextHeight: CGFloat = QuestionStepView.clampedFreeTextHeight(
        0, lineHeight: QuestionStepView.freeTextLineHeight)

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Constants.Conversation.QuestionWizard.controlSpacing) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(question.header.uppercased())
                        .font(.caption.weight(.semibold))
                        .kerning(0.5)
                        .foregroundStyle(Theme.mutedForeground(for: colorScheme))
                        .fixedSize(horizontal: false, vertical: true)
                    Text(question.question)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(Theme.foreground(for: colorScheme))
                        .fixedSize(horizontal: false, vertical: true)
                }
                VStack(spacing: Constants.Conversation.QuestionWizard.optionSpacing) {
                    ForEach(question.options.indices, id: \.self) { optionIndex in
                        optionButton(optionIndex)
                    }
                }
                otherField
            }
            .padding(.horizontal, Constants.Conversation.QuestionWizard.contentHorizontalPadding)
            .padding(.top, 10)
            .padding(.bottom, 8)
            .onGeometryChange(for: CGFloat.self) { proxy in
                proxy.size.height
            } action: { height in
                onContentHeight(step, height)
            }
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(maxHeight: contentHeight.map { min($0, maximumHeight) } ?? maximumHeight)
    }

    @ViewBuilder
    private func optionButton(_ optionIndex: Int) -> some View {
        let option = question.options[optionIndex]
        let selected = selectedIndices.contains(optionIndex)
        Button {
            onSelect(optionIndex)
        } label: {
            HStack(spacing: Constants.Conversation.QuestionWizard.controlSpacing) {
                if isMulti {
                    checkbox(selected)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(option.label)
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(Theme.foreground(for: colorScheme))
                        .fixedSize(horizontal: false, vertical: true)
                    if let description = option.description {
                        Text(description)
                            .font(.caption)
                            .foregroundStyle(Theme.mutedForeground(for: colorScheme))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
                if !isMulti {
                    Image(systemName: "arrow.right")
                        .font(.caption)
                        .foregroundStyle(Theme.mutedForeground(for: colorScheme).opacity(0.6))
                }
            }
            .frame(
                maxWidth: .infinity,
                minHeight: Constants.Accessibility.minimumTapTarget,
                alignment: .leading)
            .padding(.horizontal, Constants.Conversation.QuestionWizard.optionHorizontalPadding)
            .padding(.vertical, Constants.Conversation.QuestionWizard.optionVerticalPadding)
            .background(
                selected
                    ? Theme.primary(for: colorScheme).opacity(
                        colorSchemeContrast == .increased ? 0.2 : 0.1)
                    : Theme.background(for: colorScheme).opacity(0.6)
            )
            .clipShape(RoundedRectangle(
                cornerRadius: Constants.Conversation.QuestionWizard.optionCornerRadius))
            .overlay(
                RoundedRectangle(
                    cornerRadius: Constants.Conversation.QuestionWizard.optionCornerRadius)
                    .strokeBorder(
                        selected
                            ? Theme.primary(for: colorScheme)
                            : Theme.border(
                                for: colorScheme, contrast: colorSchemeContrast).opacity(
                                    colorSchemeContrast == .increased ? 1 : 0.4),
                        lineWidth: selected || colorSchemeContrast == .increased ? 2 : 1
                    )
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(option.label)
        .accessibilityValue(selected ? "Selected" : "Not selected")
    }

    @ViewBuilder
    private func checkbox(_ selected: Bool) -> some View {
        RoundedRectangle(cornerRadius: Constants.Conversation.QuestionWizard.checkboxCornerRadius)
            .fill(selected ? Theme.primary(for: colorScheme) : Color.clear)
            .frame(width: checkboxSide, height: checkboxSide)
            .overlay(
                RoundedRectangle(
                    cornerRadius: Constants.Conversation.QuestionWizard.checkboxCornerRadius)
                    .strokeBorder(
                        selected
                            ? Color.clear
                            : Theme.mutedForeground(
                                for: colorScheme, contrast: colorSchemeContrast).opacity(
                                    colorSchemeContrast == .increased ? 1 : 0.5),
                        lineWidth: colorSchemeContrast == .increased ? 2 : 1
                    )
            )
            .overlay {
                if selected {
                    Image(systemName: "checkmark")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.white)
                }
            }
    }

    private static let freeTextPlaceholder = "Type your own answer…"

    /// One body line of the free-text field, measured with the font
    /// `SubmittableTextView` installs.
    static var freeTextLineHeight: CGFloat {
        UIFont.preferredFont(forTextStyle: .body).lineHeight
    }

    /// Clamps the free-text field's reported content height between one
    /// line and `freeTextMaximumLineCount` lines (plus the text container
    /// insets); past the cap the text view scrolls.
    static func clampedFreeTextHeight(_ contentHeight: CGFloat, lineHeight: CGFloat) -> CGFloat {
        let insets = Constants.Conversation.Composer.textContainerInset * 2
        let minimum = lineHeight + insets
        let maximum = lineHeight
            * CGFloat(Constants.Conversation.QuestionWizard.freeTextMaximumLineCount) + insets
        return min(max(contentHeight, minimum), maximum)
    }

    /// Multiline free-text answer. Reuses the composer's `SubmittableTextView`
    /// so hardware Return submits and Shift+Return inserts a newline under
    /// the same `ComposerSubmitPolicy` as the composer; the return-key hint
    /// is shown only where bare Return actually submits.
    private var otherField: some View {
        HStack(spacing: 8) {
            Image(systemName: "pencil")
                .font(.caption)
                .foregroundStyle(Theme.mutedForeground(for: colorScheme).opacity(0.6))
            ZStack(alignment: .leading) {
                SubmittableTextView(
                    text: $freeText,
                    isFocused: $freeTextFocused,
                    onSubmit: onSubmit,
                    onHeightChange: { height in
                        freeTextHeight = Self.clampedFreeTextHeight(
                            height, lineHeight: Self.freeTextLineHeight)
                    },
                    hoverCornerRadius: Constants.Conversation.QuestionWizard.optionCornerRadius,
                    accessibilityLabel: Self.freeTextPlaceholder
                )
                .frame(height: freeTextHeight)
                // UITextView has no built-in placeholder; offset by the
                // container inset plus UITextView's default lineFragmentPadding.
                if freeText.isEmpty {
                    Text(Self.freeTextPlaceholder)
                        .font(.body)
                        .foregroundStyle(Theme.mutedForeground(for: colorScheme))
                        .padding(.leading, Constants.Conversation.Composer.textContainerInset + 5)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            .frame(maxWidth: .infinity, minHeight: Constants.Accessibility.minimumTapTarget)
            .contentShape(Rectangle())
            .onTapGesture { freeTextFocused = true }
            .onChange(of: freeText) { _, _ in onTextChange() }
            if KeyCommandTextView.returnSubmitsNow {
                Image(systemName: "return")
                    .font(.caption)
                    .foregroundStyle(Theme.mutedForeground(for: colorScheme).opacity(0.5))
            }
        }
        .padding(.horizontal, Constants.Conversation.QuestionWizard.optionHorizontalPadding)
        .padding(.vertical, Constants.Conversation.QuestionWizard.optionVerticalPadding)
        .frame(minHeight: Constants.Accessibility.minimumTapTarget)
        .background(Theme.background(for: colorScheme).opacity(0.7))
        .clipShape(RoundedRectangle(
            cornerRadius: Constants.Conversation.QuestionWizard.optionCornerRadius))
    }
}