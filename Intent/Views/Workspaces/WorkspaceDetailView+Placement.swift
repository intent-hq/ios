import CoreText
import SwiftUI

/// Where the workspace page sits: a phone page, the shell's main pane, or the shell sidebar beside
/// an open agent or note.
extension WorkspaceDetailView {
    var surface: Color {
        guard sidebar != nil else { return WorkspaceDetailStyle.background(for: colorScheme) }
        return coordinator.usesIPadShell ? IPadSidebarStyle.background(for: colorScheme) : Theme.sidebar(for: colorScheme)
    }

    /// Below the iPad pane header, the title's cap top meets the sidebar's filter control and the
    /// repository line starts at the control's bottom edge.
    static let iPadHeadingTopSpacing = IPadSidebarStyle.sectionSpacing - Constants.Conversation.Design.IPad.headerBottomInset

    /// The persistent iPad sidebar already names the workspace above its list selection.
    var sidebarHeadingTopSpacing: CGFloat? { sidebar != nil ? 0 : nil }

    /// The Duo sidebar page shows its title in the fixed header and sits on the list's inset.
    var isDuoSidebar: Bool { sidebar != nil && usesVerticalBar }

    var pageHeadingTopSpacing: CGFloat? {
        if usesIPadPaneTitle { return Self.iPadHeadingTopSpacing }
        return coordinator.usesIPadShell && usesVerticalBar ? Self.duoHeadingTopSpacing : nil
    }

    /// The Duo overview has no header band, so its title's first line sits on the sidebar
    /// header row, where "Workspaces" is centered.
    static var duoHeadingTopSpacing: CGFloat {
        let style = Constants.Typography.heading2
        let capHeight = CTFontGetCapHeight(CTFontCreateWithName(style.face.rawValue as CFString, style.size, nil))
        return IPadSidebarStyle.topInset + (Constants.WorkspaceSearch.compactHeight - capHeight) / 2
    }

    /// The iPad main pane's title follows the iPad comp; the unfolded Duo keeps its rail layout.
    var usesIPadPaneTitle: Bool { coordinator.usesIPadShell && !usesVerticalBar }

    var isBesideIPadSidebar: Bool {
        coordinator.usesIPadShell && coordinator.iPadNavigation.isSidebarVisible && !coordinator.iPadNavigation.usesSidebarOverlay
    }

    var firstAgent: WorkspaceFirstAgent? {
        viewModel.foregroundAgents.first.map { WorkspaceFirstAgent(id: $0.id, workspaceId: workspaceId, name: $0.name) }
    }
}
