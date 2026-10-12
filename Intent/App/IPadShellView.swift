import SwiftUI

/// One view hierarchy spans expanded, collapsed and drawer layouts. In particular,
/// the workspace and Assistant detail subtrees never move between containers.
struct IPadShellView: View {
    let session: BackendSession
    @Environment(AppCoordinator.self) private var coordinator
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Nil until measured, so a zero first width never drives the navigation layout.
    @State private var width: CGFloat?
    @State private var isSearchingWorkspaces = false
    @State private var showingCreateWorkspace = false
    @State private var showingConnectionSwitcher = false
    @State private var connectionSwitcherOpen = false
    @AccessibilityFocusState private var detailFocused: Bool

    private var navigation: IPadNavigationState { coordinator.iPadNavigation }
    private var layout: IPadShellLayout {
        IPadShellLayout(width: width ?? 0, isAccessibilitySize: dynamicTypeSize.isAccessibilitySize)
    }
    private var measuredLayout: IPadShellLayout? { width.map { _ in layout } }
    private var sidebarPresentation: SidebarPresentation {
        SidebarPresentation(isVisible: navigation.isSidebarVisible, usesOverlay: navigation.usesSidebarOverlay)
    }
    private var isDrawerVisible: Bool { navigation.usesSidebarOverlay && navigation.isSidebarVisible }
    private var workspaceActionsEnabled: Bool {
        navigation.section == .workspaces && navigation.pairing == nil && !showingCreateWorkspace
    }

    var body: some View {
        AgentHistoryDrawer(isEnabled: workspaceActionsEnabled && !connectionSwitcherOpen) {
            WorkspaceConnectionSwitcher(
                isPresented: $showingConnectionSwitcher,
                isEnabled: workspaceActionsEnabled,
                onReveal: collapseSidebar
            ) {
                shell
            }
        }
        .environment(\.conversationPresentation, .iPad)
        .onPreferenceChange(ConnectionSwitcherOpenPreference.self) { connectionSwitcherOpen = $0 }
        .onChange(of: coordinator.shouldDismissWorkspaceCreation) { _, dismiss in
            if dismiss { showingCreateWorkspace = false }
        }
        .onChange(of: session.connection.currentPrincipal?.isOwner) {
            coordinator.onIPadAssistantAccessChanged()
        }
        .sheet(isPresented: $showingCreateWorkspace) {
            CreateWorkspaceView(session: session, coordinator: coordinator)
        }
    }

    private var shell: some View {
        HStack(alignment: .top, spacing: layout.gutter) {
            IPadNavigationRail(
                section: navigation.section,
                isSidebarVisible: navigation.isSidebarVisible,
                canUseAssistant: coordinator.canUseAssistant,
                onSelect: coordinator.onSelectIPadSection
            ) {
                coordinator.iPadNavigation.revealSidebar()
            }
            ZStack(alignment: .leading) {
                detailPane
                drawerBackdrop
                sidebarPane
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(layout.inset)
        .opacity(width == nil ? 0 : 1)
        .background(Constants.Pairing.background(for: colorScheme).ignoresSafeArea())
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { if $0 > 0 { width = $0 } }
        .onChange(of: measuredLayout, initial: true) { _, measuredLayout in
            guard let measuredLayout else { return }
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                coordinator.iPadNavigation.updateLayout(usesOverlay: measuredLayout.usesSidebarOverlay)
            }
        }
        .onChange(of: sidebarPresentation) { old, new in
            // Layout changes (first measurement, rotation) must not move VoiceOver focus.
            if old.usesOverlay == new.usesOverlay, old.isVisible, !new.isVisible { detailFocused = true }
        }
    }

    private var detailPane: some View {
        detail
            .padding(.leading, layout.detailLeadingInset(sidebarVisible: navigation.isSidebarVisible))
            .animation(reduceMotion ? nil : IPadShellLayout.sidebarAnimation, value: navigation.isSidebarVisible)
            .environment(\.isIPadPaneVisible, !isDrawerVisible)
            .allowsHitTesting(!isDrawerVisible)
            .accessibilityFocused($detailFocused)
    }

    private var sidebarPane: some View {
        sidebars
            .frame(width: layout.sidebarWidth)
            .frame(maxHeight: .infinity)
            .background(Constants.Pairing.background(for: colorScheme))
            .clipShape(RoundedRectangle(cornerRadius: IPadShellLayout.cornerRadius))
            .offset(x: navigation.isSidebarVisible ? 0 : -layout.sidebarWidth)
            .opacity(navigation.isSidebarVisible ? 1 : 0)
            .animation(reduceMotion ? nil : IPadShellLayout.sidebarAnimation, value: navigation.isSidebarVisible)
            .clipped()
            .allowsHitTesting(navigation.isSidebarVisible)
            .environment(\.isIPadPaneVisible, navigation.isSidebarVisible)
    }

    private var detail: some View {
        ZStack {
            RetainedIPadPane(
                isVisible: navigation.detail == .workspace && navigation.pairing == nil,
                keepsCoveredContentVisible: true
            ) {
                IPadWorkspaceDetailView(session: session)
            }
            if navigation.hasOpenedAssistant {
                RetainedIPadPane(
                    isVisible: navigation.detail == .assistant && navigation.pairing == nil,
                    keepsCoveredContentVisible: true
                ) {
                    AssistantView(session: session)
                }
            }
            if let pairing = navigation.pairing {
                IPadPairingDetail(mode: pairing) { coordinator.iPadNavigation.cancelPairing() }
                    .accessibilityHidden(true, isEnabled: isDrawerVisible)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Constants.Conversation.Design.Palette.background(for: colorScheme))
        .clipShape(RoundedRectangle(cornerRadius: IPadShellLayout.cornerRadius))
        .shadow(
            color: .black.opacity(IPadShellLayout.shadowOpacity),
            radius: IPadShellLayout.shadowRadius,
            y: IPadShellLayout.shadowOffset
        )
        .accessibilityElement(children: .contain)
    }

    private var sidebars: some View {
        ZStack {
            RetainedIPadPane(isVisible: navigation.section == .workspaces) {
                WorkspaceListSidebar(
                    workspaceStore: session.workspaceStore,
                    isSearching: $isSearchingWorkspaces,
                    onCreateWorkspace: createWorkspace,
                    onCollapse: collapseSidebar
                )
            }
            if navigation.hasOpenedAssistant {
                RetainedIPadPane(isVisible: navigation.section == .assistant) {
                    IPadAssistantSidebar(
                        session: session,
                        onCollapse: collapseSidebar
                    ) { coordinator.onSelectAssistant(agentId: $0) }
                }
            }
            RetainedIPadPane(isVisible: navigation.section == .connections) {
                IPadConnectionsSidebar(
                    onCollapse: collapseSidebar,
                    onScanQR: { coordinator.iPadNavigation.presentPairing(.qrCode) },
                    onManualPairing: { coordinator.iPadNavigation.presentPairing(.manual) }
                )
            }
            RetainedIPadPane(isVisible: navigation.section == .settings) {
                IPadSettingsSidebar(
                    onCollapse: collapseSidebar,
                    onScanQR: { coordinator.iPadNavigation.presentPairing(.qrCode) },
                    onManualPairing: { coordinator.iPadNavigation.presentPairing(.manual) }
                )
            }
        }
    }

    private var drawerBackdrop: some View {
        ZStack {
            if isDrawerVisible {
                Button(action: collapseSidebar) {
                    Color.black.opacity(IPadShellLayout.drawerShadeOpacity)
                        .contentShape(Rectangle())
                }
                .buttonStyle(IntentContentButtonStyle())
                .accessibilityLabel("Close sidebar")
                .accessibilityIdentifier("ipad.sidebar.dismiss")
                .transition(.opacity)
            }
        }
        .animation(reduceMotion ? nil : IPadShellLayout.sidebarAnimation, value: isDrawerVisible)
        .allowsHitTesting(isDrawerVisible)
        .accessibilityHidden(!isDrawerVisible)
    }

    private func collapseSidebar() {
        coordinator.iPadNavigation.collapseSidebar()
    }

    private func createWorkspace() {
        guard coordinator.canCreateWorkspace else { return }
        showingConnectionSwitcher = false
        showingCreateWorkspace = true
    }
}

private struct SidebarPresentation: Equatable {
    let isVisible: Bool
    let usesOverlay: Bool
}
