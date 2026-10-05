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

    private enum Layout {
        static let spacing: CGFloat = 8
        static let padding: CGFloat = 12
        static let cornerRadius: CGFloat = 12
    }

    var body: some View {
        let segments = WorkspaceLinks.parse(text, isStreaming: isStreaming)
        // Resolve workspace availability on MainActor, outside row providers.
        let rows = segments.enumerated().map { (offset: $0.offset, content: segmentContent($0.element)) }
        VStack(alignment: .leading, spacing: Layout.spacing) {
            ForEach(rows, id: \.offset) { @Sendable row in
                row.content
            }
            .id(segments.count)
        }
    }

    @ViewBuilder
    private func segmentContent(_ segment: WorkspaceLinks.Segment) -> some View {
        switch segment {
        case .markdown(let markdown):
            MarkdownTextView(text: markdown, onOpenURL: onOpenURL, workspaceId: workspaceId)
        case .workspaces(let ids):
            let rows = ids.filter { !coveredIDs.contains($0) }.map { id in
                (id: id, content: workspaceButton(id))
            }
            ForEach(rows, id: \.id) { @Sendable row in
                row.content
            }
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
            .copyContextMenuPassthrough()
            .background(Theme.muted(for: colorScheme), in: RoundedRectangle(cornerRadius: Layout.cornerRadius))
            .contentShape(RoundedRectangle(cornerRadius: Layout.cornerRadius))
        }
        .buttonStyle(.plain)
        .disabled(workspace == nil)
        .accessibilityIdentifier("assistant.workspace.\(id)")
    }
}

extension EnvironmentValues {
    @Entry var assistantMessageStreaming = false
    @Entry var proposalMessageId = ""
    @Entry var proposalWorkspaceIDs: Set<String> = []
}
