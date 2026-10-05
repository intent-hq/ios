import SwiftUI

struct WorkspaceLinkedTextView: View {
    let text: String
    let workspaceId: String
    var onOpenURL: (URL) -> OpenURLAction.Result
    @Environment(BackendSession.self) private var session
    @Environment(AppCoordinator.self) private var coordinator
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.assistantMessageStreaming) private var isStreaming
    @Environment(\.proposalWorkspaceIDs) private var coveredIDs
    @ScaledMetric(relativeTo: .body) private var iconSide: CGFloat = 17

    private enum Layout {
        static let spacing: CGFloat = 8
        static let padding: CGFloat = 12
        static let cornerRadius: CGFloat = 12
    }

    var body: some View {
        let segments = WorkspaceLinks.parse(text, isStreaming: isStreaming)
        VStack(alignment: .leading, spacing: Layout.spacing) {
            ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                switch segment {
                case .markdown(let markdown):
                    MarkdownTextView(text: markdown, onOpenURL: onOpenURL, workspaceId: workspaceId)
                case .workspaces(let ids):
                    ForEach(ids.filter { !coveredIDs.contains($0) }, id: \.self) { id in
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
                Image(.spaces)
                    .resizable()
                    .scaledToFit()
                    .frame(width: iconSide, height: iconSide)
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
                Image(.chevronRight)
                    .resizable()
                    .scaledToFit()
                    .frame(width: iconSide, height: iconSide)
                    .accessibilityHidden(true)
            }
            .foregroundStyle(workspace == nil
                ? Theme.mutedForeground(for: colorScheme)
                : Theme.foreground(for: colorScheme))
            .padding(Layout.padding)
            .copyContextMenuPassthrough()
            .background(Theme.muted(for: colorScheme), in: RoundedRectangle(cornerRadius: Layout.cornerRadius))
            .contentShape(RoundedRectangle(cornerRadius: Layout.cornerRadius))
        }
        .buttonStyle(IntentContentButtonStyle())
        .disabled(workspace == nil)
        .accessibilityIdentifier("assistant.workspace.\(id)")
    }
}

extension EnvironmentValues {
    @Entry var assistantMessageStreaming = false
    @Entry var proposalMessageId = ""
    @Entry var proposalWorkspaceIDs: Set<String> = []
}
