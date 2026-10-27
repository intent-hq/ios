import SwiftUI

/// Chrome for the workspace overview while it sits in a persistent sidebar
/// beside one of its agents or notes.
struct WorkspaceDetailSidebar {
    let onBack: () -> Void
    /// The iPad shell draws its own header; the Duo split view uses the column's navigation bar.
    var onCollapse: (() -> Void)?

    var headingTopSpacing: CGFloat { onCollapse == nil ? WorkspaceDetailStyle.headingSpacing : 0 }
}

struct WorkspaceSidebarHeader<Actions: View>: View {
    let onBack: () -> Void
    let onCollapse: () -> Void
    @ViewBuilder let actions: () -> Actions

    var body: some View {
        IPadSidebarHeader(onCollapse: onCollapse) {
            WorkspaceSidebarBackButton(action: onBack)
                // Align the arrow, not its tap target, with the sidebar's content edge.
                .padding(.leading, (WorkspaceDetailStyle.iconSize - WorkspaceDetailStyle.controlSize) / 2)
        } actions: {
            actions()
        }
    }
}

private struct WorkspaceSidebarBackButton: View {
    let action: () -> Void

    var body: some View {
        IntentIconButton(icon: .arrowLeft, label: "Back to workspaces", showsBackground: false, action: action)
            .accessibilityIdentifier("workspaceSidebar.back")
    }
}

extension View {
    @ViewBuilder
    func workspaceSidebarNavigation<Actions: View>(
        _ sidebar: WorkspaceDetailSidebar,
        @ViewBuilder actions: @escaping () -> Actions
    ) -> some View {
        if sidebar.onCollapse == nil {
            toolbarTitleDisplayMode(.inline)
                .navigationBarBackButtonHidden()
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) { WorkspaceSidebarBackButton(action: sidebar.onBack) }
                        .intentToolbarSurface()
                    ToolbarItem(placement: .topBarTrailing) { actions() }
                        .intentToolbarSurface()
                }
        } else {
            self
        }
    }

    /// Marks the open agent or note in a sidebar workspace with the sidebar's selection surface.
    func workspaceSidebarSelection(_ isSelected: Bool) -> some View {
        modifier(WorkspaceSidebarSelection(isSelected: isSelected))
    }
}

private struct WorkspaceSidebarSelection: ViewModifier {
    private static let outset: CGFloat = 12

    let isSelected: Bool
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.conversationPresentation) private var presentation

    func body(content: Content) -> some View {
        content
            .background {
                if isSelected {
                    RoundedRectangle(cornerRadius: IPadSidebarStyle.rowRadius, style: .continuous)
                        .fill(presentation == .iPad
                            ? IPadSidebarStyle.selection(for: colorScheme)
                            : Theme.sidebarSelection(for: colorScheme))
                        .padding(-Self.outset)
                }
            }
            .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
