import SwiftUI

struct ConversationGoalStrip: View {
    let goal: String
    let onSave: (String) async -> String?
    let onRemove: () async -> Void
    @State private var state = ConversationGoalStripState.collapsed
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast
    @ScaledMetric(relativeTo: .subheadline) private var iconSize = Constants.Conversation.Design.Goal.iconSize

    private typealias Design = Constants.Conversation.Design
    private typealias Goal = Constants.Conversation.Design.Goal

    var body: some View {
        HStack(alignment: .top, spacing: Goal.contentSpacing) {
            Image(.pin)
                .resizable()
                .scaledToFit()
                .frame(width: iconSize, height: iconSize)
                .foregroundStyle(Design.Palette.secondaryForeground(for: colorScheme, contrast: contrast))
                .accessibilityHidden(true)
                .frame(minHeight: Design.minimumTapTarget)
            goalText
                .frame(maxWidth: .infinity, alignment: .leading)
            actions
        }
        .padding(.horizontal, Design.horizontalInset)
        .padding(.vertical, Goal.verticalPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Design.Palette.background(for: colorScheme))
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Design.Palette.border(for: colorScheme, contrast: contrast))
                .frame(height: Constants.Conversation.DividerNotice.lineHeight)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("goalStrip")
        .sheet(isPresented: editorPresented) {
            ConversationGoalEditor(
                text: Binding(get: { state.draft?.text ?? "" }, set: { state.updateDraft($0) }),
                failure: state.draft?.failure,
                isSaving: state.isSaving,
                canSave: state.canSave,
                onCancel: { state.cancelEditing() },
                onSave: save
            )
            .coversConversationComposers()
        }
        .onChange(of: goal) { _, _ in
            if state.isExpanded { state.toggleExpansion() }
        }
    }

    @ViewBuilder private var goalText: some View {
        if state.isExpanded {
            Text(ConversationGoal.linkedText(goal))
                .interFont(Constants.Typography.bodyXS)
                .foregroundStyle(Design.Palette.foreground(for: colorScheme))
                .tint(Design.Palette.foreground(for: colorScheme))
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .frame(minHeight: Design.minimumTapTarget, alignment: .leading)
                .accessibilityLabel("Goal: \(goal)")
                .accessibilityIdentifier("goalStrip.text")
        } else {
            Button { state.toggleExpansion() } label: {
                Text(goal)
                    .interFont(Constants.Typography.bodyXS)
                    .foregroundStyle(Design.Palette.foreground(for: colorScheme))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, minHeight: Design.minimumTapTarget, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(IntentContentButtonStyle())
            .accessibilityLabel("Goal: \(goal)")
            .accessibilityHint("Shows the full goal")
            .accessibilityIdentifier("goalStrip.text")
        }
    }

    private var actions: some View {
        HStack(spacing: Goal.actionSpacing) {
            actionButton(
                icon: state.isExpanded ? .chevronUp : .chevronDown,
                label: state.isExpanded ? "Show less of the goal" : "Show the full goal",
                identifier: "goalStrip.toggle"
            ) { state.toggleExpansion() }
            .accessibilityValue(state.isExpanded ? "Expanded" : "Collapsed")
            actionButton(icon: .edit, label: "Edit goal", identifier: "goalStrip.edit") {
                state.beginEditing(goal: goal)
            }
            actionButton(icon: .close, label: "Remove goal", identifier: "goalStrip.remove") {
                Task { await onRemove() }
            }
        }
        .requiresLiveConnection()
    }

    private func actionButton(icon: ImageResource, label: String, identifier: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(icon)
                .resizable()
                .scaledToFit()
                .frame(width: iconSize, height: iconSize)
                .foregroundStyle(Design.Palette.secondaryForeground(for: colorScheme, contrast: contrast))
                .frame(minWidth: Design.minimumTapTarget, minHeight: Design.minimumTapTarget)
                .contentShape(Rectangle())
        }
        .buttonStyle(IntentContentButtonStyle())
        .accessibilityLabel(label)
        .accessibilityIdentifier(identifier)
    }

    private var editorPresented: Binding<Bool> {
        Binding(get: { state.isEditorPresented }, set: { if !$0 { state.cancelEditing() } })
    }

    private func save() {
        guard let text = state.beginSaving() else { return }
        Task {
            let failure = await onSave(text)
            state.finishSaving(failure: failure)
        }
    }
}

struct ConversationGoalEditor: View {
    @Binding var text: String
    let failure: String?
    let isSaving: Bool
    let canSave: Bool
    let onCancel: () -> Void
    let onSave: () -> Void
    @FocusState private var focused: Bool
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast

    private typealias Design = Constants.Conversation.Design

    private var characterCount: Int { ConversationGoal.length(text) }

    var body: some View {
        NavigationStack {
            editorContent
                .padding(Design.horizontalInset)
                .background(Design.Palette.background(for: colorScheme))
                .navigationTitle("Edit goal")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { editorToolbar }
        }
        .interactiveDismissDisabled(isSaving)
        .onAppear { focused = true }
    }

    private var editorContent: some View {
        VStack(alignment: .leading, spacing: Design.Goal.editorSpacing) {
            TextEditor(text: $text)
                .interFont(Constants.Typography.bodyS)
                .focused($focused)
                .frame(minHeight: Design.Goal.editorMinimumHeight)
                .scrollContentBackground(.hidden)
                .padding(Design.Goal.editorSpacing)
                .background(Design.Palette.surface(for: colorScheme), in: .rect(cornerRadius: Design.innerCornerRadius))
                .disabled(isSaving)
                .accessibilityLabel("Goal")
                .accessibilityHint("Describe what done looks like. Save an empty goal to remove it.")
                .accessibilityIdentifier("goalEditor.text")
            Text("\(characterCount) of \(ConversationGoal.maximumLength) characters. Leave it empty to remove the goal.")
                .interFont(Constants.Typography.subtextXXS)
                .foregroundStyle(Design.Palette.secondaryForeground(for: colorScheme, contrast: contrast))
                .fixedSize(horizontal: false, vertical: true)
            if let failure {
                Text(failure)
                    .interFont(Constants.Typography.bodyXS)
                    .foregroundStyle(Design.Palette.blockerForeground(for: colorScheme, contrast: contrast))
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("goalEditor.error")
            }
            Spacer(minLength: 0)
        }
    }

    @ToolbarContentBuilder private var editorToolbar: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button("Cancel", action: onCancel)
                .disabled(isSaving)
                .accessibilityIdentifier("goalEditor.cancel")
        }
        ToolbarItem(placement: .confirmationAction) {
            if isSaving {
                ProgressView().accessibilityLabel("Saving goal")
            } else {
                Button("Save", action: onSave)
                    .disabled(!canSave)
                    .accessibilityIdentifier("goalEditor.save")
            }
        }
    }
}
