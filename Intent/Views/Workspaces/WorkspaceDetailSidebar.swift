import SwiftUI

/// Chrome for the workspace overview while it sits in a persistent sidebar
/// beside one of its agents or notes. The main view's Back leaves it.
struct WorkspaceDetailSidebar {
    /// The iPad shell draws its own header; the Duo split view uses the column's navigation bar.
    var onCollapse: (() -> Void)?

    var headingTopSpacing: CGFloat { onCollapse == nil ? WorkspaceDetailStyle.headingSpacing : 0 }
}

/// Collapse leads, where the list's title would be; workspace actions trail.
struct WorkspaceSidebarHeader<Actions: View>: View {
    let onCollapse: () -> Void
    @ViewBuilder let actions: () -> Actions
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.isIPadPaneVisible) private var isPaneVisible

    var body: some View {
        HStack(spacing: 0) {
            IntentIconButton(icon: .collapseLeft, label: "Hide sidebar", showsBackground: false, action: onCollapse)
                .accessibilityIdentifier("ipad.sidebar.collapse")
                .accessibilityAction(.escape, onCollapse)
                // Align the icon, not its tap target, with the sidebar's content edge.
                .padding(.leading, (WorkspaceDetailStyle.iconSize - WorkspaceDetailStyle.controlSize) / 2)
            Spacer(minLength: 0)
            actions()
        }
        .opacity(isPaneVisible ? 1 : 0)
        .foregroundStyle(Constants.Pairing.foreground(for: colorScheme))
        .padding(.horizontal, IPadSidebarStyle.inset)
        .padding(.top, IPadSidebarStyle.topInset)
        .padding(.bottom, IPadSidebarStyle.sectionSpacing)
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
