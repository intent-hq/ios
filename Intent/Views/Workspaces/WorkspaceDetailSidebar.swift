import SwiftUI

/// Chrome for the workspace overview while it sits in the iPad shell's sidebar
/// beside one of its agents or notes. The main view's Back leaves it.
struct WorkspaceDetailSidebar {
    let onCollapse: () -> Void
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

/// The Duo's sidebar workspace names itself in the list header's slot: same component,
/// type and insets as "Workspaces", fixed above the scrolling page.
struct WorkspaceSidebarTitleHeader: View {
    let title: String

    /// The Duo header shows no collapse control, so its action is never invoked.
    private static func ignoreCollapse() {}

    var body: some View {
        IPadSidebarHeader(onCollapse: Self.ignoreCollapse) {
            Text(title)
                .interFont(IPadSidebarStyle.titleStyle)
                .tracking(IPadSidebarStyle.titleTracking)
                .fixedSize(horizontal: false, vertical: true)
                // The list's row is as tall as its controls; this one has none.
                .frame(minHeight: Constants.WorkspaceSearch.compactHeight)
                .accessibilityAddTraits(.isHeader)
        } actions: {
            EmptyView()
        }
    }
}

extension View {
    /// Marks the open agent or note in a sidebar workspace with the sidebar's selection surface.
    func workspaceSidebarSelection(_ isSelected: Bool) -> some View {
        modifier(WorkspaceSidebarSelection(isSelected: isSelected))
    }
}

private struct WorkspaceSidebarSelection: ViewModifier {
    private static let outset: CGFloat = 12

    let isSelected: Bool
    @Environment(\.workspaceUsesVerticalBar) private var usesVerticalBar
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
                        .padding(.vertical, -Self.outset)
                        // The Duo page sits on the list's 8 pt inset, so the fill stops at the column edge.
                        .padding(.horizontal, -(usesVerticalBar ? IPadSidebarStyle.compactInset : Self.outset))
                }
            }
            .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
