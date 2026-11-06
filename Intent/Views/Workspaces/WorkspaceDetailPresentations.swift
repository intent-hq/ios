import SwiftUI

/// Presents the workspace page's confirmations, sheets, resources, and failure alerts.
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
            .fullScreenCover(
                item: $presentation.selectedTerminal,
                onDismiss: {
                    // The terminal already showed any error inline; don't replay it as an alert.
                    terminalStore.clearError(workspaceId: workspaceId)
                },
                content: { terminal in
                    MobileTerminalView(terminal: terminal, workspaceName: workspaceName, store: terminalStore)
                }
            )
            .modifier(WorkspaceDetailAlerts(presentation: presentation, workspaceId: workspaceId))
    }

    private func presentSelectedBrowser() {
        if let browser = presentation.selectedBrowser { session.browserNavigation.presentUserBrowser(browser) }
        presentation.selectedBrowser = nil
    }
}

/// Archive and delete ask first: an alert on iPhone and iPad, a focused sheet on visionOS.
private struct WorkspaceActionConfirmations: ViewModifier {
    @Bindable var presentation: WorkspaceDetailPresentation
    let onArchive: () -> Void
    let onDelete: () -> Void

    func body(content: Content) -> some View {
        content
        #if os(visionOS)
        // Deliberate confirmation sheets (HIG): destructive/irreversible
        // workspace actions get a focused sheet with one primary action.
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
        } message: {
            Text("Are you sure you want to delete this workspace? This cannot be undone.")
        }
        .alert("Archive Workspace", isPresented: $presentation.showArchiveConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Archive", action: onArchive)
        } message: {
            Text("Archive this workspace? You can unarchive it later.")
        }
        #endif
    }
}

/// The terminal and workspace-action failures that the page reports over itself.
private struct WorkspaceDetailAlerts: ViewModifier {
    let presentation: WorkspaceDetailPresentation
    let workspaceId: String
    @Environment(BackendSession.self) private var session

    private var terminalStore: MobileTerminalStore { session.mobileTerminalStore }

    func body(content: Content) -> some View {
        content
            .alert("Terminal unavailable", isPresented: Binding(
                get: { terminalStore.errorMessage(workspaceId: workspaceId) != nil && presentation.selectedTerminal == nil },
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
