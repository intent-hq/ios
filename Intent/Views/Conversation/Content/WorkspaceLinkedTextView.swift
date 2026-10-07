import SwiftUI

struct WorkspaceLinkedTextView: View {
    let text: String
    let workspaceId: String
    var onOpenURL: (URL) -> OpenURLAction.Result
    @Environment(BackendSession.self) private var session
    @Environment(AppCoordinator.self) private var coordinator
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.legibilityWeight) private var legibilityWeight
    @Environment(\.workspaceTranscriptDesign) private var usesWorkspaceDesign
    @Environment(\.assistantMessageStreaming) private var isStreaming
    @Environment(\.proposalWorkspaceIDs) private var coveredIDs
    @ScaledMetric(relativeTo: .body) private var iconSide: CGFloat = 17

    private enum Layout {
        static let spacing: CGFloat = 8
        static let padding: CGFloat = 12
        static let cornerRadius: CGFloat = 12
    }

    private typealias Design = Constants.Conversation.Design

    private var cornerRadius: CGFloat { usesWorkspaceDesign ? Design.innerCornerRadius : Layout.cornerRadius }
    private var secondaryForeground: Color {
        usesWorkspaceDesign ? Design.Palette.secondaryForeground(for: colorScheme, contrast: contrast) : Theme.mutedForeground(for: colorScheme)
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
                Image(.spaces)
                    .resizable()
                    .scaledToFit()
                    .frame(width: iconSide, height: iconSide)
                    .accessibilityHidden(true)
                VStack(alignment: .leading) {
                    Text(workspace?.title ?? id)
                        .font(usesWorkspaceDesign ? Constants.Typography.bodySEmphasized.font(legibilityWeight: legibilityWeight) : .body.weight(.medium))
                    if workspace == nil {
                        Text("Workspace unavailable")
                            .font(usesWorkspaceDesign ? Constants.Typography.subtextXXS.font(legibilityWeight: legibilityWeight) : .caption)
                            .foregroundStyle(usesWorkspaceDesign ? AnyShapeStyle(secondaryForeground) : AnyShapeStyle(.secondary))
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
                ? secondaryForeground
                : usesWorkspaceDesign ? Design.Palette.foreground(for: colorScheme) : Theme.foreground(for: colorScheme))
            .padding(usesWorkspaceDesign ? Design.Transcript.bubblePadding : Layout.padding)
            .copyContextMenuPassthrough()
            .background(usesWorkspaceDesign ? Design.Palette.surface(for: colorScheme) : Theme.muted(for: colorScheme), in: .rect(cornerRadius: cornerRadius))
            .contentShape(.rect(cornerRadius: cornerRadius))
        }
        .buttonStyle(IntentContentButtonStyle())
        .overlay {
            if usesWorkspaceDesign {
                RoundedRectangle(cornerRadius: cornerRadius)
                    .strokeBorder(Design.Palette.border(for: colorScheme, contrast: contrast))
                    .allowsHitTesting(false)
            }
        }
        .disabled(workspace == nil)
        .accessibilityIdentifier("assistant.workspace.\(id)")
    }
}

extension EnvironmentValues {
    @Entry var assistantMessageStreaming = false
    @Entry var proposalMessageId = ""
    @Entry var proposalWorkspaceIDs: Set<String> = []
}
