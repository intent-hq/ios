import SwiftUI

struct WorkspaceLinkedTextView: View {
    let text: String
    let workspaceId: String
    var onOpenURL: (URL) -> OpenURLAction.Result
    @Environment(BackendSession.self) private var session
    @Environment(AppCoordinator.self) private var coordinator
    @Environment(\.colorScheme) private var colorScheme

    private enum Layout {
        static let spacing: CGFloat = 8
        static let padding: CGFloat = 12
        static let cornerRadius: CGFloat = 12
    }

    var body: some View {
        let segments = WorkspaceLinks.parse(text)
        VStack(alignment: .leading, spacing: Layout.spacing) {
            ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                switch segment {
                case .markdown(let markdown):
                    MarkdownTextView(text: markdown, onOpenURL: onOpenURL, workspaceId: workspaceId)
                case .workspaces(let ids):
                    ForEach(ids, id: \.self) { id in
                        workspaceButton(id)
                    }
                }
            }
            .id(segments.count)
        }
    }

    private func workspaceButton(_ id: String) -> some View {
        let workspace = session.workspaceStore.workspaces.first { $0.id == id }
        return Button {
            coordinator.onSelectWorkspace(id)
        } label: {
            HStack(spacing: Layout.spacing) {
                Image(systemName: "rectangle.stack")
                    .accessibilityHidden(true)
                VStack(alignment: .leading) {
                    Text(workspace?.title ?? id)
                        .font(.body.weight(.medium))
                    if workspace == nil {
                        Text("Workspace unavailable")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .accessibilityHidden(true)
            }
            .padding(Layout.padding)
            .background(Theme.muted(for: colorScheme), in: RoundedRectangle(cornerRadius: Layout.cornerRadius))
            .contentShape(RoundedRectangle(cornerRadius: Layout.cornerRadius))
        }
        .buttonStyle(.plain)
        .disabled(workspace == nil)
        .accessibilityIdentifier("assistant.workspace.\(id)")
    }
}
