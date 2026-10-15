import SwiftUI

/// One view hierarchy spans expanded, collapsed and drawer layouts. In particular,
/// the workspace and Assistant detail subtrees never move between containers.
struct IPadShellView: View {
    let session: BackendSession
    @Environment(AppCoordinator.self) private var coordinator
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    /// Nil until measured, so a zero first width never drives the navigation layout.
    @State private var width: CGFloat?
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
    private var isFocused: Bool { navigation.focusPresentation != .normal }
    private var isEditing: Bool { navigation.focusPresentation == .conversationEditing }
    private var isDrawerVisible: Bool { navigation.usesSidebarOverlay && navigation.isSidebarVisible && !isFocused }
    private var isDetailAccessible: Bool { !isDrawerVisible && !workspaceSearchVisible }
    private var isSidebarAccessible: Bool { (navigation.isSidebarVisible || workspaceSearchVisible) && !isEditing }
    private var focusPresentation: Binding<IPadFocusPresentation> {
        Binding(get: { navigation.focusPresentation }, set: { coordinator.iPadNavigation.setFocusPresentation($0) })
    }
    private var isSearchingWorkspaces: Binding<Bool> {
        Binding(
            get: { navigation.focusPresentation == .workspaceSearch },
            set: { coordinator.iPadNavigation.setFocusPresentation($0 ? .workspaceSearch : .normal) }
        )
    }
    private var workspaceActionsEnabled: Bool {
        navigation.section == .workspaces && navigation.pairing == nil && !showingCreateWorkspace && !isFocused
    }
    private var showsWorkspaceList: Bool {
        if case .workspaceList = coordinator.currentScreen { return true }
        return false
    }
    private var workspaceSearchVisible: Bool {
        navigation.focusPresentation == .workspaceSearch
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
        .environment(\.iPadFocusPresentation, focusPresentation)
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
        ZStack(alignment: .topLeading) {
            if !layout.usesCompactNavigation {
                navigationRail
            }
            detailPane
                .padding(layout.inset)
                .zIndex(isEditing ? IPadShellLayout.focusLayer : 0)
            drawerBackdrop
                .frame(width: layout.contentWidth)
                .offset(x: layout.railLeadingInset)
                .padding(layout.inset)
                .zIndex(1)
            sidebarPane
                .padding(layout.inset)
                .zIndex(workspaceSearchVisible ? IPadShellLayout.focusLayer : 1)
            if isFocused {
                // Keep the shade outside pane padding so it reaches the full
                // window, including the status bar and the shell's outer gutter.
                Color.black.opacity(IPadShellLayout.focusShadeOpacity)
                    .ignoresSafeArea()
                    .accessibilityHidden(true)
                    .zIndex(2)
            }
        }
        .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .opacity(width == nil ? 0 : 1)
        .background(IPadShellStyle.background(for: colorScheme).ignoresSafeArea())
        .modifier(WorkspaceActionLauncher(
            isSearching: workspaceSearchVisible,
            isEnabled: width != nil && layout.usesCompactNavigation && !isFocused,
            onWorkspaces: { coordinator.onSelectIPadSection(.workspaces) },
            onAssistant: { coordinator.onSelectIPadSection(.assistant) },
            onCreateWorkspace: createWorkspace,
            onConnections: showConnections
        ))
        .accessibilityAction(.escape) { coordinator.iPadNavigation.setFocusPresentation(.normal) }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { if $0 > 0 { width = $0 } }
        .onChange(of: measuredLayout, initial: true) { _, measuredLayout in
            if let measuredLayout {
                coordinator.iPadNavigation.updateLayout(
                    usesOverlay: measuredLayout.usesSidebarOverlay,
                    usesCompactNavigation: measuredLayout.usesCompactNavigation,
                    showsWorkspaceList: showsWorkspaceList
                )
                coordinator.ensureIPadWorkspaceSelection()
            }
        }
        .onChange(of: sidebarPresentation) { old, new in
            // Layout changes (first measurement, rotation) must not move VoiceOver focus.
            if old.usesOverlay == new.usesOverlay, old.isVisible, !new.isVisible { detailFocused = true }
        }
    }

    private var navigationRail: some View {
        IPadNavigationRail(
            section: navigation.section,
            isSidebarVisible: navigation.isSidebarVisible,
            canUseAssistant: coordinator.canUseAssistant,
            onSelect: coordinator.onSelectIPadSection
        ) {
            coordinator.iPadNavigation.revealSidebar()
        }
        .blur(radius: isFocused ? IPadShellLayout.focusBlurRadius : 0)
        .allowsHitTesting(!isFocused)
        .accessibilityHidden(isFocused)
        .padding(layout.inset)
        // Keep normal navigation above native pane containers' hit regions.
        .zIndex(isFocused ? 0 : 2)
    }

    private var detailPane: some View {
        detail
            .frame(width: isEditing ? layout.focusedPanelWidth : max(0, layout.contentWidth - layout.detailLeadingInset(sidebarVisible: navigation.isSidebarVisible)))
            .modifier(IPadPaneBounds(identifier: "ipad.detail.panel", isAccessible: isDetailAccessible))
            .padding(.leading, isEditing ? 0 : layout.railLeadingInset + layout.detailLeadingInset(sidebarVisible: navigation.isSidebarVisible))
            .frame(maxWidth: .infinity, alignment: isEditing ? .center : .leading)
            .blur(radius: workspaceSearchVisible ? IPadShellLayout.focusBlurRadius : 0)
            .environment(\.isIPadPaneVisible, isDetailAccessible)
            .allowsHitTesting(isDetailAccessible)
            .accessibilityFocused($detailFocused)
    }

    private var sidebarPane: some View {
        sidebars
            .safeAreaPadding(.bottom, layout.usesCompactNavigation && !workspaceSearchVisible ? AssistantLaunchButton.scrollClearance : 0)
            .frame(width: workspaceSearchVisible ? layout.focusedPanelWidth : layout.sidebarWidth)
            .frame(maxHeight: .infinity)
            .background(IPadShellStyle.background(for: colorScheme))
            .clipShape(RoundedRectangle(cornerRadius: IPadShellLayout.cornerRadius))
            .modifier(IPadPaneBounds(identifier: "ipad.sidebar.panel", isAccessible: isSidebarAccessible))
            .padding(.leading, workspaceSearchVisible ? 0 : layout.railLeadingInset)
            .frame(maxWidth: .infinity, alignment: workspaceSearchVisible ? .center : .leading)
            .blur(radius: isEditing ? IPadShellLayout.focusBlurRadius : 0)
            .opacity(navigation.isSidebarVisible || workspaceSearchVisible ? 1 : 0)
            .allowsHitTesting(isSidebarAccessible)
            .environment(\.isIPadPaneVisible, isSidebarAccessible)
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
        .background(IPadShellStyle.panel(for: colorScheme))
        .clipShape(RoundedRectangle(cornerRadius: IPadShellLayout.cornerRadius))
        .shadow(
            color: .black.opacity(IPadShellLayout.shadowOpacity),
            radius: IPadShellLayout.shadowRadius,
            y: IPadShellLayout.shadowOffset
        )
    }

    private var sidebars: some View {
        ZStack {
            RetainedIPadPane(isVisible: navigation.section == .workspaces, keepsCoveredContentVisible: true) {
                WorkspaceListSidebar(
                    workspaceStore: session.workspaceStore,
                    isSearching: isSearchingWorkspaces,
                    onCreateWorkspace: createWorkspace,
                    onCollapse: collapseSidebar
                )
            }
            if navigation.hasOpenedAssistant {
                RetainedIPadPane(isVisible: navigation.section == .assistant, keepsCoveredContentVisible: true) {
                    IPadAssistantSidebar(
                        session: session,
                        onCollapse: collapseSidebar
                    ) { coordinator.onSelectAssistant(agentId: $0) }
                }
            }
            RetainedIPadPane(isVisible: navigation.section == .connections, keepsCoveredContentVisible: true) {
                IPadConnectionsSidebar(
                    onCollapse: collapseSidebar,
                    onScanQR: { coordinator.iPadNavigation.presentPairing(.qrCode) },
                    onManualPairing: { coordinator.iPadNavigation.presentPairing(.manual) }
                )
            }
            RetainedIPadPane(isVisible: navigation.section == .settings, keepsCoveredContentVisible: true) {
                IPadSettingsSidebar(
                    onCollapse: collapseSidebar,
                    onScanQR: { coordinator.iPadNavigation.presentPairing(.qrCode) },
                    onManualPairing: { coordinator.iPadNavigation.presentPairing(.manual) }
                )
            }
        }
    }

    @ViewBuilder private var drawerBackdrop: some View {
        if isDrawerVisible {
            Button(action: collapseSidebar) {
                Color.black.opacity(IPadShellLayout.drawerShadeOpacity)
                    .contentShape(Rectangle())
            }
            .buttonStyle(IntentContentButtonStyle())
            .accessibilityLabel("Close sidebar")
            .accessibilityIdentifier("ipad.sidebar.dismiss")
        }
    }

    private func collapseSidebar() {
        guard !layout.usesCompactNavigation || !showsWorkspaceList || navigation.section != .workspaces else { return }
        coordinator.iPadNavigation.collapseSidebar()
    }

    private func showConnections() {
        coordinator.onSelectIPadSection(.connections)
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
