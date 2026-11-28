import SwiftUI

struct ConversationGoalPill: View {
    let goal: String
    let onSave: (String) async -> String?
    let onRemove: () async -> Void
    @State private var state = ConversationGoalPillState.idle

    var body: some View {
        Button(action: edit) {
            WorkspaceStatusPill(icon: .mapPin, text: Text(verbatim: goal))
        }
        .buttonStyle(IntentContentButtonStyle())
        .disabled(state.isRemoving)
        .requiresLiveConnection()
        .contextMenu {
            Button(action: edit) {
                Label("Edit goal", image: "Edit")
            }
            Button(role: .destructive, action: remove) {
                Label("Remove goal", image: "Close")
            }
        }
        .accessibilityLabel("Goal: \(goal)")
        .accessibilityHint("Edits the goal")
        .accessibilityAction(named: "Remove goal", remove)
        .accessibilityIdentifier("goalPill")
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
    }

    private func edit() {
        state.beginEditing(goal: goal)
    }

    private func remove() {
        guard state.beginRemoving() else { return }
        Task {
            await onRemove()
            state.finishRemoving()
        }
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
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

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
        .presentationDetents(dynamicTypeSize.isAccessibilitySize ? [.large] : [.medium, .large])
        .interactiveDismissDisabled(isSaving)
        .onAppear { focused = true }
    }

    private var editorContent: some View {
        VStack(alignment: .leading, spacing: Design.Goal.editorSpacing) {
            TextEditor(text: $text)
                .interFont(Constants.Typography.bodyS)
                .focused($focused)
                .frame(minHeight: Design.Goal.editorMinimumHeight, maxHeight: .infinity)
                .scrollContentBackground(.hidden)
                .padding(Design.Goal.editorSpacing)
                .background(Design.Palette.surface(for: colorScheme), in: .rect(cornerRadius: Design.innerCornerRadius))
                .disabled(isSaving)
                .accessibilityLabel("Goal")
                .accessibilityHint("Describe what done looks like. Save an empty goal to remove it.")
                .accessibilityIdentifier("goalEditor.text")
            Text(verbatim: "\(characterCount)/\(ConversationGoal.maximumLength)")
                .interFont(Constants.Typography.subtextXXS)
                .monospacedDigit()
                .foregroundStyle(Design.Palette.secondaryForeground(for: colorScheme, contrast: contrast))
                .accessibilityLabel("\(characterCount) of \(ConversationGoal.maximumLength) characters")
                .accessibilityIdentifier("goalEditor.count")
            if let failure {
                Text(failure)
                    .interFont(Constants.Typography.bodyXS)
                    .foregroundStyle(Design.Palette.blockerForeground(for: colorScheme, contrast: contrast))
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("goalEditor.error")
            }
        }
    }

    @ToolbarContentBuilder private var editorToolbar: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            IntentIconButton(icon: .close, label: "Cancel", action: onCancel)
                .disabled(isSaving)
                .accessibilityIdentifier("goalEditor.cancel")
        }
        .intentToolbarSurface()
        ToolbarItem(placement: .confirmationAction) {
            if isSaving {
                ProgressView().accessibilityLabel("Saving goal")
            } else {
                Button("Save", action: onSave)
                    .buttonStyle(IntentButtonStyle())
                    .fixedSize(horizontal: true, vertical: false)
                    .disabled(!canSave)
                    .accessibilityIdentifier("goalEditor.save")
            }
        }
        .intentToolbarSurface()
    }
}
