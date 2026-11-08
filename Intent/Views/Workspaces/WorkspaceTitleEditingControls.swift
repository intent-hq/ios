import SwiftUI

struct WorkspaceTitleEditingControls: View {
    let editor: WorkspaceTitleEditor
    let onSave: () -> Void
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.isRemoteReadOnly) private var isRemoteReadOnly

    var body: some View {
        HStack(spacing: WorkspaceDetailStyle.headingSpacing) {
            CreateWorkspaceNavigationButton(
                control: .close,
                identifier: "workspace.title.cancel",
                onAction: editor.cancel
            )
            .disabled(editor.isSaving)
            .accessibilityLabel("Cancel editing workspace name")
            Spacer()
            Button(action: onSave) {
                HStack {
                    if editor.isSaving { ProgressView().tint(Theme.foreground(for: colorScheme)) }
                    Text(editor.isSaving ? "Saving…" : "Done")
                        .lineLimit(1)
                }
            }
            .buttonStyle(IntentButtonStyle())
            .fixedSize(horizontal: true, vertical: false)
            .disabled(editor.isSaving || isRemoteReadOnly)
            .accessibilityIdentifier("workspace.title.done")
        }
        .padding(.horizontal, WorkspaceDetailStyle.pageInset)
        .padding(.vertical, WorkspaceDetailStyle.headingSpacing)
    }
}
