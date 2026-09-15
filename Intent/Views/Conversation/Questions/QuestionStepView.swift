import SwiftUI

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

    private static let titleSpacing: CGFloat = 3
    private static let contentTopPadding: CGFloat = 10
    private static let contentBottomPadding: CGFloat = 8
    private static let secondaryLabelOpacity = 0.6
    private static let selectedHighContrastOpacity = 0.2
    private static let selectedOpacity = 0.1
    private static let optionBackgroundOpacity = 0.6
    private static let standardBorderOpacity = 0.4
    private static let otherFieldSpacing: CGFloat = 8
    private static let otherFieldBackgroundOpacity = 0.7

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Constants.Conversation.QuestionWizard.controlSpacing) {
                VStack(alignment: .leading, spacing: Self.titleSpacing) {
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
            .padding(.top, Self.contentTopPadding)
            .padding(.bottom, Self.contentBottomPadding)
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
        .buttonStyle(.plain)
        .accessibilityLabel(option.label)
        .accessibilityValue(selected ? "Selected" : "Not selected")
    }

    private func optionLabel(_ option: QuestionOption, selected: Bool) -> some View {
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
                    .foregroundStyle(Theme.mutedForeground(for: colorScheme).opacity(Self.secondaryLabelOpacity))
                    .accessibilityHidden(true)
            }
        }
    }

    private func optionBackground(selected: Bool) -> Color {
        selected
            ? Theme.primary(for: colorScheme).opacity(
                colorSchemeContrast == .increased ? Self.selectedHighContrastOpacity : Self.selectedOpacity
            )
            : Theme.background(for: colorScheme).opacity(Self.optionBackgroundOpacity)
    }

    private func optionBorder(selected: Bool) -> some View {
        RoundedRectangle(cornerRadius: Constants.Conversation.QuestionWizard.optionCornerRadius)
            .strokeBorder(
                selected
                    ? Theme.primary(for: colorScheme)
                    : Theme.border(for: colorScheme, contrast: colorSchemeContrast)
                        .opacity(colorSchemeContrast == .increased ? 1 : Self.standardBorderOpacity),
                lineWidth: selected || colorSchemeContrast == .increased ? 2 : 1
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
                                .opacity(colorSchemeContrast == .increased ? 1 : 0.5),
                        lineWidth: colorSchemeContrast == .increased ? 2 : 1
                    )
            )
            .overlay {
                if selected {
                    Image(systemName: "checkmark")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.white)
                        .accessibilityHidden(true)
                }
            }
    }

    private var otherField: some View {
        HStack(spacing: Self.otherFieldSpacing) {
            Image(systemName: "pencil")
                .font(.caption)
                .foregroundStyle(Theme.mutedForeground(for: colorScheme).opacity(Self.secondaryLabelOpacity))
                .accessibilityHidden(true)
            TextField("Type your own answer…", text: $freeText)
                .font(.body)
                .foregroundStyle(Theme.foreground(for: colorScheme))
                .frame(minHeight: Constants.Accessibility.minimumTapTarget)
                .onSubmit(onSubmit)
                .onChange(of: freeText) { _, _ in onTextChange() }
            Image(systemName: "return")
                .font(.caption)
                .foregroundStyle(Theme.mutedForeground(for: colorScheme).opacity(0.5))
                .accessibilityHidden(true)
        }
        .padding(.horizontal, Constants.Conversation.QuestionWizard.optionHorizontalPadding)
        .padding(.vertical, Constants.Conversation.QuestionWizard.optionVerticalPadding)
        .frame(minHeight: Constants.Accessibility.minimumTapTarget)
        .background(Theme.background(for: colorScheme).opacity(Self.otherFieldBackgroundOpacity))
        .clipShape(RoundedRectangle(
            cornerRadius: Constants.Conversation.QuestionWizard.optionCornerRadius
        ))
    }
}
