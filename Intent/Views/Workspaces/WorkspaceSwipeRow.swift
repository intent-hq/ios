import SwiftUI

struct WorkspaceSwipeRow: View {
    let workspace: Workspace
    let showRepo: Bool
    let isUpdating: Bool
    @Binding var revealedWorkspaceId: String?
    let onSelect: () -> Void
    let onAction: (WorkspaceAction) -> Void
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .body) private var actionWidth: CGFloat = 88
    @State private var translation: CGFloat = 0

    private var actionsWidth: CGFloat { actionWidth * 2 }
    private var isRevealed: Bool { revealedWorkspaceId == workspace.id }
    private var offset: CGFloat { max(-actionsWidth, min(0, (isRevealed ? -actionsWidth : 0) + translation)) }
    private var revealBinding: Binding<Bool> {
        Binding(
            get: { isRevealed },
            set: { revealed in
                if revealed {
                    revealedWorkspaceId = workspace.id
                } else if isRevealed {
                    revealedWorkspaceId = nil
                }
            }
        )
    }

    var body: some View {
        workspaceButton
            .background(Constants.WorkspaceList.canvas(for: colorScheme))
            .offset(x: offset)
            .background(alignment: .trailing) {
                if isRevealed || translation < 0 { actionButtons }
            }
            .clipped()
            .contentShape(Rectangle())
            .modifier(WorkspaceRowSwipeGesture(translation: $translation, isRevealed: revealBinding))
            .animation(reduceMotion ? nil : .snappy, value: isRevealed)
            .onChange(of: translation) { previous, current in
                if previous == 0, current != 0, !isRevealed { revealedWorkspaceId = nil }
            }
            .onDisappear {
                if isRevealed { revealedWorkspaceId = nil }
            }
            .overlay(alignment: .bottom) { Divider() }
    }

    private var workspaceButton: some View {
        Button {
            if revealedWorkspaceId != nil {
                revealedWorkspaceId = nil
            } else {
                onSelect()
            }
        } label: {
            WorkspaceRowView(workspace: workspace, colorScheme: colorScheme, showRepo: showRepo, spacious: true)
                .overlay(alignment: .trailing) {
                    if isUpdating { ProgressView().padding(.trailing) }
                }
        }
        .buttonStyle(.plain)
        .disabled(isUpdating)
        .accessibilityIdentifier("workspace.row.\(workspace.id)")
        .contextMenu { menuActions }
        .accessibilityActions { menuActions }
    }

    private var actionButtons: some View {
        HStack(spacing: 0) {
            actionButton(.archive, systemImage: "archivebox", color: .orange)
            actionButton(.delete, systemImage: "trash", color: .red)
        }
        .frame(width: actionsWidth)
        .buttonStyle(.plain)
        .disabled(isUpdating)
        .allowsHitTesting(isRevealed)
        .accessibilityHidden(!isRevealed)
    }

    private func actionButton(_ action: WorkspaceAction, systemImage: String, color: Color) -> some View {
        Button { select(action) } label: {
            VStack {
                Image(systemName: systemImage).accessibilityHidden(true)
                Text(action.label).interFont(Constants.Typography.bodyXS)
            }
            .frame(width: actionWidth)
            .frame(minHeight: Constants.Accessibility.minimumTapTarget, maxHeight: .infinity)
            .foregroundStyle(.white)
            .background(color)
            .contentShape(Rectangle())
        }
        .accessibilityLabel("\(action.label) workspace")
        .accessibilityIdentifier("workspace.\(action.rawValue).\(workspace.id)")
    }

    private var menuActions: some View {
        Group {
            Button("Archive workspace", systemImage: "archivebox") { select(.archive) }
            Button("Delete workspace", systemImage: "trash", role: .destructive) { select(.delete) }
        }
        .disabled(isUpdating)
    }

    private func select(_ action: WorkspaceAction) {
        revealedWorkspaceId = nil
        onAction(action)
    }
}
