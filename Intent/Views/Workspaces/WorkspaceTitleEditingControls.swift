import SwiftUI

struct WorkspaceTitleEditingControls: View {
    let editor: WorkspaceTitleEditor
    let onSave: () -> Void
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: WorkspaceDetailStyle.headingSpacing) {
            Button("Cancel", action: editor.cancel)
                .interFont(Constants.Typography.bodyS)
                .foregroundStyle(Theme.foreground(for: colorScheme))
                .frame(minHeight: Constants.Accessibility.minimumTapTarget)
                .disabled(editor.isSaving)
                .accessibilityIdentifier("workspace.title.cancel")
            Button(action: onSave) {
                HStack {
                    if editor.isSaving { ProgressView().tint(Theme.background(for: colorScheme)) }
                    Text(editor.isSaving ? "Saving…" : "Done")
                        .interFont(Constants.Typography.bodyM.withFace(.semibold))
                }
                .padding(.horizontal, WorkspaceDetailStyle.pageInset)
                .frame(minHeight: Constants.Accessibility.minimumTapTarget)
                .foregroundStyle(Theme.background(for: colorScheme))
                .background(Theme.foreground(for: colorScheme), in: Capsule())
            }
            .buttonStyle(.plain)
            .disabled(editor.isSaving)
            .accessibilityIdentifier("workspace.title.done")
        }
        .padding(.horizontal, WorkspaceDetailStyle.pageInset)
        .padding(.vertical, WorkspaceDetailStyle.headingSpacing)
    }
}
