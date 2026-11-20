import Foundation

@MainActor
struct IPadWorkspaceAutoSelection {
    let usesIPadShell: Bool
    let navigation: IPadNavigationState
    let screen: AppScreen
    let includeArchived: Bool
    let presentation: WorkspaceListPresentation

    func workspaceId(in workspaces: @autoclosure () -> [Workspace]) -> String? {
        guard usesIPadShell, navigation.hasMeasuredLayout, !navigation.usesCompactNavigation,
              navigation.section == .workspaces, navigation.pairing == nil,
              case .workspaceList = screen else { return nil }
        let rows = WorkspaceListRows.visible(workspaces(), includeArchived: includeArchived, presentation: presentation)
        return rows.first { $0.id != Workspace.chiefWorkspaceId }?.id
    }
}
