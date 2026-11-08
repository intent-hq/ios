import SwiftUI

/// The standalone page's navigation chrome and the actions menu it shares with the sidebar copy.
extension WorkspaceDetailView {
    var pageContent: some View {
        presentedContent
        .preference(key: WorkspaceFirstAgentPreference.self, value: firstAgent)
        .navigationTitle(showsNavigationTitle ? workspaceName : "")
        .toolbar(removing: usesVerticalBar ? .title : nil)
        .toolbarTitleDisplayMode(.inline)
        #if !os(visionOS)
        .navigationBarBackButtonHidden()
        .nativeNavigationBackGesture()
        .toolbarBackground(WorkspaceDetailStyle.background(for: colorScheme), for: .navigationBar)
        #endif
        .toolbar {
            // In the Duo shell the rail carries these actions, as for conversations; a system
            // vertical toolbar would add an opaque navigation bar over the top of the pane.
            if usesVerticalBar, !coordinator.usesIPadShell {
                WorkspaceVerticalNavigationToolbar(
                    isEnabled: true,
                    showsBackButton: showsBackButton && !isSidebarVisible,
                    backLabel: "Back to workspaces",
                    backIdentifier: "workspaceDetail.back",
                    onBack: coordinator.onBackToWorkspaceList
                ) { workspaceActions }
            } else if !usesVerticalBar {
                #if os(visionOS)
                // The workspace picker lives in the top toolbar on visionOS.
                ToolbarItem(placement: .topBarTrailing) { WorkspaceDetailToolbarPicker(selection: tabSelection) }
                #else
                if showsBackButton {
                    ToolbarItem(placement: .topBarLeading) {
                        IntentIconButton(icon: .arrowLeft, label: "Back to workspaces", showsBackground: false, action: coordinator.onBackToWorkspaceList)
                            .accessibilityIdentifier("workspaceDetail.back")
                    }
                    .intentToolbarSurface()
                }
                #endif
                if showsNavigationTitle {
                    ToolbarItem(placement: .principal) {
                        WorkspaceDetailToolbarTitle(title: workspaceTitle, createdAt: workspace?.createdAt)
                    }
                }
                ToolbarItem(placement: .primaryAction) { workspaceActions }
                .intentToolbarSurface()
            }
        }
        #if !os(visionOS)
        .workspacePhoneNavigation(
            title: workspaceTitle,
            createdAt: workspace?.createdAt,
            showsBackButton: showsBackButton,
            showsTitle: !isBesideIPadSidebar,
            onBack: coordinator.onBackToWorkspaceList
        ) { workspaceActions }
        #endif
    }

    var workspaceActions: some View {
        WorkspaceResourceActions(workspaceId: workspaceId) {
            workspaceActionsMenu
        }
    }

    var workspaceActionsMenu: some View {
        WorkspaceActionsMenu(
            workspaceId: workspaceId,
            scriptStore: scriptStore,
            isTerminalDisabled: !terminalStore.isConnected || terminalStore.creatingWorkspaces.contains(workspaceId),
            onCreateAgent: { presentation.showSpecialistPicker = true },
            onCreateTerminal: createTerminal,
            onCreateBrowser: { presentation.showNewBrowser = true },
            onTransfer: session.connection.currentPrincipal?.isOwner == true
                && session.connection.connectionState == .connected ? { presentation.showTransferWorkspace = true } : nil,
            onCollapseSidebar: usesVerticalBar ? nil : sidebar?.onCollapse,
            onArchive: { presentation.showArchiveConfirmation = true },
            onDelete: { presentation.showDeleteConfirmation = true }
        )
    }

    private func createTerminal() {
        let requestedWorkspace = workspaceId
        let request = UUID()
        presentation.terminalCreationRequest = request
        Task {
            let terminal = await terminalStore.create(workspaceId: requestedWorkspace)
            if presentation.terminalCreationRequest == request { presentation.selectedTerminal = terminal }
        }
    }
}
