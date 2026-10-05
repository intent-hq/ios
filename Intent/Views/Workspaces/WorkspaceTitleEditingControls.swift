import SwiftUI

struct WorkspaceTitleEditingControls: View {
    let editor: WorkspaceTitleEditor
    let onSave: () -> Void
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: WorkspaceDetailStyle.headingSpacing) {
            Button(action: editor.cancel) {
                Text("Cancel")
                    .interFont(Constants.Typography.bodyS)
                    .lineLimit(1)
                    .padding(.horizontal, WorkspaceDetailStyle.headingSpacing)
                    .frame(minHeight: Constants.Accessibility.minimumTapTarget)
                    .foregroundStyle(Theme.foreground(for: colorScheme))
                    .background(Theme.background(for: colorScheme), in: Capsule())
            }
            .buttonStyle(.plain)
            .disabled(editor.isSaving)
            .accessibilityIdentifier("workspace.title.cancel")
            Button(action: onSave) {
                HStack {
                    if editor.isSaving { ProgressView().tint(Theme.background(for: colorScheme)) }
                    Text(editor.isSaving ? "Saving…" : "Done")
                        .interFont(Constants.Typography.bodyM.withFace(.semibold))
                        .lineLimit(1)
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
        .fixedSize(horizontal: true, vertical: false)
        .padding(.horizontal, WorkspaceDetailStyle.pageInset)
        .frame(maxWidth: .infinity, alignment: .trailing)
        .padding(.vertical, WorkspaceDetailStyle.headingSpacing)
    }
}
