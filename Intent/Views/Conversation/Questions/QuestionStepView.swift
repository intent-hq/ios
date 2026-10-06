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
    var isActive = true

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @ScaledMetric(relativeTo: .caption) private var actionIconSide: CGFloat = 12
    @ScaledMetric(relativeTo: .caption) private var checkboxSide =
        Constants.Conversation.QuestionWizard.checkboxSide
    @State private var freeTextFocused = false
    @State private var freeTextHeight: CGFloat = Self.clampedFreeTextHeight(
        0,
        lineHeight: Self.freeTextLineHeight
    )

    private typealias Layout = Constants.Conversation.QuestionWizard.Step
    // The text container has a top and a bottom inset; this is not a visual scale.
    private static let textContainerVerticalInsetMultiplier: CGFloat = 2

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Constants.Conversation.QuestionWizard.controlSpacing) {
                VStack(alignment: .leading, spacing: Layout.titleSpacing) {
                    Text(question.header.uppercased())
                        .interFont(Constants.Typography.eyebrow.withFace(.semibold))
                        .kerning(Layout.headerKerning)
                        .foregroundStyle(Theme.mutedForeground(for: colorScheme))
                        .fixedSize(horizontal: false, vertical: true)
                    Text(question.question)
                        .interFont(Constants.Typography.bodyXSEmphasized)
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
            .padding(.top, Layout.contentTopPadding)
            .padding(.bottom, Layout.contentBottomPadding)
            .onGeometryChange(for: CGFloat.self) { proxy in
                proxy.size.height
            } action: { height in
                onContentHeight(step, height)
            }
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(maxHeight: contentHeight.map { min($0, maximumHeight) } ?? maximumHeight)
        .onChange(of: isActive) { _, active in
            if !active { freeTextFocused = false }
        }
    }

    @ViewBuilder
    private func optionButton(_ optionIndex: Int) -> some View {
        let option = question.options[optionIndex]
        let selected = selectedIndices.contains(optionIndex)
        Button {
            onSelect(optionIndex)
        } label: {
            optionLabel(option, selected: selected)
            .frame(
                maxWidth: .infinity,
                minHeight: Constants.Accessibility.minimumTapTarget,
                alignment: .leading
            )
            .padding(.horizontal, Constants.Conversation.QuestionWizard.optionHorizontalPadding)
            .padding(.vertical, Constants.Conversation.QuestionWizard.optionVerticalPadding)
            .background(optionBackground(selected: selected))
            .clipShape(RoundedRectangle(
                cornerRadius: Constants.Conversation.QuestionWizard.optionCornerRadius
            ))
            .overlay(optionBorder(selected: selected))
            .contentShape(Rectangle())
        }
        .buttonStyle(IntentContentButtonStyle())
        .accessibilityLabel(option.label)
        .accessibilityValue(selected ? "Selected" : "Not selected")
    }

    private func optionLabel(_ option: QuestionOption, selected: Bool) -> some View {
        HStack(spacing: Constants.Conversation.QuestionWizard.controlSpacing) {
            if isMulti {
                checkbox(selected)
            }
            VStack(alignment: .leading, spacing: Layout.optionLabelSpacing) {
                Text(option.label)
                    .interFont(Constants.Typography.bodyXSEmphasized)
                    .foregroundStyle(Theme.foreground(for: colorScheme))
                    .fixedSize(horizontal: false, vertical: true)
                if let description = option.description {
                    Text(description)
                        .interFont(Constants.Typography.subtextXXS)
                        .foregroundStyle(Theme.mutedForeground(for: colorScheme))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .multilineTextAlignment(.leading)
            Spacer(minLength: 0)
            if !isMulti {
                Image(.arrowRight)
                    .resizable()
                    .scaledToFit()
                    .frame(width: actionIconSide, height: actionIconSide)
                    .foregroundStyle(Theme.mutedForeground(for: colorScheme).opacity(Layout.secondaryLabelOpacity))
                    .accessibilityHidden(true)
            }
        }
    }

    private func optionBackground(selected: Bool) -> Color {
        selected
            ? Theme.primary(for: colorScheme).opacity(
                colorSchemeContrast == .increased ? Layout.selectedHighContrastOpacity : Layout.selectedOpacity
            )
            : Theme.background(for: colorScheme).opacity(Layout.optionBackgroundOpacity)
    }

    private func optionBorder(selected: Bool) -> some View {
        RoundedRectangle(cornerRadius: Constants.Conversation.QuestionWizard.optionCornerRadius)
            .strokeBorder(
                selected
                    ? Theme.primary(for: colorScheme)
                    : Theme.border(for: colorScheme, contrast: colorSchemeContrast)
                        .opacity(colorSchemeContrast == .increased ? 1 : Layout.standardBorderOpacity),
                lineWidth: selected || colorSchemeContrast == .increased
                    ? Layout.optionEmphasizedBorderWidth : Layout.optionBorderWidth
            )
    }

    @ViewBuilder
    private func checkbox(_ selected: Bool) -> some View {
        RoundedRectangle(cornerRadius: Constants.Conversation.QuestionWizard.checkboxCornerRadius)
            .fill(selected ? Theme.primary(for: colorScheme) : Color.clear)
            .frame(width: checkboxSide, height: checkboxSide)
            .overlay(
                RoundedRectangle(
                    cornerRadius: Constants.Conversation.QuestionWizard.checkboxCornerRadius
                )
                    .strokeBorder(
                        selected
                            ? Color.clear
                            : Theme.mutedForeground(
                                for: colorScheme,
                                contrast: colorSchemeContrast
                            )
                                .opacity(colorSchemeContrast == .increased ? 1 : Layout.checkboxBorderOpacity),
                        lineWidth: colorSchemeContrast == .increased
                            ? Layout.checkboxIncreasedBorderWidth : Layout.checkboxBorderWidth
                    )
            )
            .overlay {
                if selected {
                    Image(.check)
                        .resizable()
                        .scaledToFit()
                        .frame(width: actionIconSide, height: actionIconSide)
                        .foregroundStyle(.white)
                        .accessibilityHidden(true)
                }
            }
    }

    private static let freeTextPlaceholder = "Type your own answer…"

    /// One body line of the free-text field, measured with the font
    /// `SubmittableTextView` installs.
    static var freeTextLineHeight: CGFloat {
        Constants.Typography.bodyS.uiFont(compatibleWith: .current).lineHeight
    }

    /// Clamps the free-text field's reported content height between one
    /// line and `freeTextMaximumLineCount` lines (plus the text container
    /// insets); past the cap the text view scrolls.
    static func clampedFreeTextHeight(_ contentHeight: CGFloat, lineHeight: CGFloat) -> CGFloat {
        let insets = Constants.Conversation.Composer.textContainerInset
            * textContainerVerticalInsetMultiplier
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
        HStack(spacing: Layout.otherFieldSpacing) {
            Image(.edit)
                .resizable()
                .scaledToFit()
                .frame(width: actionIconSide, height: actionIconSide)
                .foregroundStyle(Theme.mutedForeground(for: colorScheme).opacity(Layout.secondaryLabelOpacity))
                .accessibilityHidden(true)
            freeTextEditor
            if KeyCommandTextView.returnSubmitsNow {
                Image(.enter)
                    .resizable()
                    .scaledToFit()
                    .frame(width: actionIconSide, height: actionIconSide)
                    .foregroundStyle(Theme.mutedForeground(for: colorScheme).opacity(Layout.returnHintOpacity))
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, Constants.Conversation.QuestionWizard.optionHorizontalPadding)
        .padding(.vertical, Constants.Conversation.QuestionWizard.optionVerticalPadding)
        .frame(minHeight: Constants.Accessibility.minimumTapTarget)
        .background(Theme.background(for: colorScheme).opacity(Layout.otherFieldBackgroundOpacity))
        .clipShape(RoundedRectangle(
            cornerRadius: Constants.Conversation.QuestionWizard.optionCornerRadius
        ))
    }

    private var freeTextEditor: some View {
        ZStack(alignment: .leading) {
            SubmittableTextView(
                text: $freeText,
                isFocused: $freeTextFocused,
                onSubmit: onSubmit,
                onHeightChange: { height in
                    freeTextHeight = Self.clampedFreeTextHeight(
                        height,
                        lineHeight: Self.freeTextLineHeight
                    )
                },
                hoverCornerRadius: Constants.Conversation.QuestionWizard.optionCornerRadius,
                accessibilityLabel: Self.freeTextPlaceholder
            )
            .frame(height: freeTextHeight)
            if freeText.isEmpty {
                Text(Self.freeTextPlaceholder)
                    .interFont(Constants.Typography.bodyS)
                    .foregroundStyle(Theme.mutedForeground(for: colorScheme))
                    .padding(
                        .leading,
                        Constants.Conversation.Composer.textContainerInset + Layout.lineFragmentPadding
                    )
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .frame(maxWidth: .infinity, minHeight: Constants.Accessibility.minimumTapTarget)
        .contentShape(Rectangle())
        .onTapGesture { freeTextFocused = true }
        .accessibilityAddTraits(.isButton)
        .onChange(of: freeText) { _, _ in onTextChange() }
    }
}
