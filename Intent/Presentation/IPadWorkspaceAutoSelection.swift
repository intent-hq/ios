import Foundation

/// Wide iPad windows keep a workspace open; compact windows start on the list.
/// The only rule for which workspace, if any, opens when nothing is selected:
/// the top visible row of the user's list.
@MainActor
struct IPadWorkspaceAutoSelection {
    let usesIPadShell: Bool
    let navigation: IPadNavigationState
    let screen: AppScreen
    let includeArchived: Bool
    let presentation: WorkspaceListPresentation

    /// `workspaces` is read only when the window would auto-select.
    func workspaceId(in workspaces: @autoclosure () -> [Workspace]) -> String? {
        guard usesIPadShell, navigation.hasMeasuredLayout, !navigation.usesCompactNavigation,
              navigation.section == .workspaces, navigation.pairing == nil,
              case .workspaceList = screen else { return nil }
        let rows = WorkspaceListRows.visible(workspaces(), includeArchived: includeArchived, presentation: presentation)
        return rows.first { $0.id != Workspace.chiefWorkspaceId }?.id
    }
}
