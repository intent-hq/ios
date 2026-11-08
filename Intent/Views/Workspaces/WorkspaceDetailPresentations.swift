import SwiftUI

struct WorkspaceDetailPresentations: ViewModifier {
    @Bindable var presentation: WorkspaceDetailPresentation
    let workspaceId: String
    let workspaceName: String
    let onArchive: () -> Void
    let onDelete: () -> Void
    let onBrowserCreated: () -> Void
    let agentStore: AgentStore
    @Environment(AppCoordinator.self) private var coordinator
    @Environment(BackendSession.self) private var session

    private var terminalStore: MobileTerminalStore { session.mobileTerminalStore }

    func body(content: Content) -> some View {
        content
            .modifier(WorkspaceActionConfirmations(presentation: presentation, onArchive: onArchive, onDelete: onDelete))
            .sheet(isPresented: $presentation.showSpecialistPicker) {
                SpecialistPickerView(
                    workspaceId: workspaceId,
                    agentStore: agentStore,
                    optionsStore: session.creationOptionsStore
                )
                    .environment(coordinator)
            }
            .sheet(
                isPresented: $presentation.showTransferWorkspace,
                onDismiss: {
                    let workspaceStore = session.workspaceStore
                    if workspaceStore.lastUpdated != nil, !workspaceStore.workspaces.contains(where: { $0.id == workspaceId }) {
                        coordinator.handleMissingWorkspace()
                    }
                },
                content: {
                    WorkspaceTransferSheet(workspaceId: workspaceId, workspaceTitle: workspaceName, session: session)
                        .environment(coordinator)
                        .id(workspaceId)
                }
            )
            .sheet(
                isPresented: $presentation.showNewBrowser,
                onDismiss: {
                    presentation.selectedBrowser = presentation.createdBrowser
                    presentation.createdBrowser = nil
                },
                content: {
                    NewWorkspaceBrowserView(workspaceId: workspaceId, store: session.browserStore) { browser in
                        onBrowserCreated()
                        presentation.createdBrowser = browser
                    }
                }
            )
            .onChange(of: presentation.selectedBrowser) { _, _ in presentSelectedBrowser() }
            .modifier(WorkspaceTerminalPresentation(
                terminal: $presentation.selectedTerminal,
                workspaceName: workspaceName,
                onDismiss: { terminalStore.clearError(workspaceId: workspaceId) }
            ))
            .modifier(WorkspaceDetailAlerts(presentation: presentation, workspaceId: workspaceId))
    }

    private func presentSelectedBrowser() {
        if let browser = presentation.selectedBrowser { session.browserNavigation.presentUserBrowser(browser) }
        presentation.selectedBrowser = nil
    }
}

private struct WorkspaceActionConfirmations: ViewModifier {
    @Bindable var presentation: WorkspaceDetailPresentation
    let onArchive: () -> Void
    let onDelete: () -> Void

    func body(content: Content) -> some View {
        content
        #if os(visionOS)
        .sheet(isPresented: $presentation.showDeleteConfirmation) {
            WorkspaceActionConfirmationSheet(
                title: "Delete Workspace",
                message: "Are you sure you want to delete this workspace? This cannot be undone.",
                actionLabel: "Delete",
                isDestructive: true,
                onConfirm: onDelete
            )
        }
        .sheet(isPresented: $presentation.showArchiveConfirmation) {
            WorkspaceActionConfirmationSheet(
                title: "Archive Workspace",
                message: "Archive this workspace? You can unarchive it later.",
                actionLabel: "Archive",
                isDestructive: false,
                onConfirm: onArchive
            )
        }
        #else
        .alert("Delete Workspace", isPresented: $presentation.showDeleteConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive, action: onDelete)
                .disabledWhileReadOnly()
        } message: {
            Text("Are you sure you want to delete this workspace? This cannot be undone.")
        }
        .alert("Archive Workspace", isPresented: $presentation.showArchiveConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Archive", action: onArchive)
                .disabledWhileReadOnly()
        } message: {
            Text("Archive this workspace? You can unarchive it later.")
        }
        #endif
    }
}

private struct WorkspaceDetailAlerts: ViewModifier {
    let presentation: WorkspaceDetailPresentation
    let workspaceId: String
    @Environment(AppCoordinator.self) private var coordinator
    @Environment(BackendSession.self) private var session

    private var terminalStore: MobileTerminalStore { session.mobileTerminalStore }

    func body(content: Content) -> some View {
        content
            .alert("Terminal unavailable", isPresented: Binding(
                get: {
                    terminalStore.errorMessage(workspaceId: workspaceId) != nil && presentation.selectedTerminal == nil
                        && !coordinator.isShowingIPadTerminal(workspaceId: workspaceId)
                },
                set: { if !$0 { terminalStore.clearError(workspaceId: workspaceId) } }
            )) {
                Button("OK") { terminalStore.clearError(workspaceId: workspaceId) }
            } message: {
                Text(terminalStore.errorMessage(workspaceId: workspaceId) ?? "")
            }
            .alert("Workspace action failed", isPresented: Binding(
                get: { presentation.actionError != nil },
                set: { if !$0 { presentation.actionError = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(presentation.actionError ?? "Please try again.")
            }
    }
}

struct ShareWorkspaceSheet: ViewModifier {
    @Bindable var presentation: WorkspaceDetailPresentation
    @Environment(BackendSession.self) private var session

    func body(content: Content) -> some View {
        content.sheet(item: $presentation.shareRequest) { request in
            ShareWorkspaceView(
                model: WorkspaceSharingModel(
                    workspaceId: request.workspaceId,
                    namesPinProvider: WorkspaceSharingModel.namesPinProvider(
                        protocolVersion: session.connection.capabilities.protocolVersion
                    )
                ) { [connection = session.connection] method, params in
                    try await connection.request(method, params: params, timeout: ConnectionManager.defaultRequestTimeout)
                }
            )
            .id(request.workspaceId)
        }
    }
}
