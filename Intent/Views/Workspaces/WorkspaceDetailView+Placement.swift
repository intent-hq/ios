import CoreText
import SwiftUI

extension WorkspaceDetailView {
    var surface: Color {
        guard sidebar != nil else { return WorkspaceDetailStyle.background(for: colorScheme) }
        return coordinator.usesIPadShell ? IPadSidebarStyle.background(for: colorScheme) : Theme.sidebar(for: colorScheme)
    }

    static let iPadHeadingTopSpacing = IPadSidebarStyle.sectionSpacing - Constants.Conversation.Design.IPad.headerBottomInset

    var sidebarHeadingTopSpacing: CGFloat? { sidebar != nil ? 0 : nil }

    var isDuoSidebar: Bool { sidebar != nil && usesVerticalBar }

    var pageHeadingTopSpacing: CGFloat? {
        if usesIPadPaneTitle { return Self.iPadHeadingTopSpacing }
        return coordinator.usesIPadShell && usesVerticalBar ? Self.duoHeadingTopSpacing : nil
    }

    static var duoHeadingTopSpacing: CGFloat {
        let style = Constants.Typography.heading2
        let capHeight = CTFontGetCapHeight(CTFontCreateWithName(style.face.rawValue as CFString, style.size, nil))
        return IPadSidebarStyle.topInset + (Constants.WorkspaceSearch.compactHeight - capHeight) / 2
    }

    var usesIPadPaneTitle: Bool { coordinator.usesIPadShell && !usesVerticalBar }

    var isBesideIPadSidebar: Bool {
        coordinator.usesIPadShell && coordinator.iPadNavigation.isSidebarVisible && !coordinator.iPadNavigation.usesSidebarOverlay
    }

    var firstAgent: WorkspaceFirstAgent? {
        viewModel.foregroundAgents.first.map { WorkspaceFirstAgent(id: $0.id, workspaceId: workspaceId, name: $0.name) }
    }
}
