import SwiftUI

/// The workspace route keeps its identity as tools move its chat into the sidebar.
struct IPadShellView: View {
    /// Pages shift this far while fading, so a slow first frame cannot turn into a visible jump.
    static let pageParallax: CGFloat = 48
    private static let sidebarChatLayer = 1.5
    private static let workspaceLayer = 0.5

    let session: BackendSession
    @Environment(AppCoordinator.self) private var coordinator
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.workspaceUsesVerticalBar) private var usesVerticalBar
    @Environment(\.workspaceVerticalBarEdge) private var verticalBarEdge
    /// Nil until measured, so a zero first width never drives the navigation layout.
    @State private var width: CGFloat?
    @State private var windowShortSide: CGFloat = .infinity
    @State private var topSafeArea: CGFloat = 0
    @ScaledMetric(relativeTo: .subheadline) private var bannerHeight = ReadOnlyBannerMetrics.collapsedHeight
    @State private var trailingSafeArea: CGFloat = 0
    @State private var leadingSafeArea: CGFloat = 0
    @State private var showingCreateWorkspace = false
    @State private var showingConnectionSwitcher = false
    @State private var connectionSwitcherOpen = false
    @AccessibilityFocusState private var focusedPane: IPadAccessiblePane?

    private var navigation: IPadNavigationState { coordinator.iPadNavigation }
    private var layout: IPadShellLayout {
        IPadShellLayout(
            width: width ?? 0,
            isAccessibilitySize: dynamicTypeSize.isAccessibilitySize,
            usesFoldableLayout: usesVerticalBar,
            usesLeadingVerticalBar: verticalBarEdge == .leading,
            windowShortSide: windowShortSide
        )
    }
    private var railSafeArea: CGFloat { verticalBarEdge == .leading ? leadingSafeArea : trailingSafeArea }
    private var railAlignment: Alignment { verticalBarEdge == .leading ? .topLeading : .topTrailing }
    private var measuredLayout: IPadShellLayout? { width.map { _ in layout } }
    /// The shell ignores vertical safe areas, so it reserves the read-only banner's space itself.
    private var bannerInset: CGFloat { coordinator.showsReadOnlyBanner ? bannerHeight : 0 }
    private var paneInsets: EdgeInsets {
        EdgeInsets(top: max(layout.inset, topSafeArea) + bannerInset, leading: layout.leadingInset, bottom: layout.inset, trailing: layout.trailingInset)
    }
    private var sidebarPresentation: SidebarPresentation {
        SidebarPresentation(isVisible: navigation.isSidebarVisible, usesOverlay: navigation.usesSidebarOverlay)
    }
    private var isFocused: Bool { navigation.focusPresentation != .normal }
    private var isEditing: Bool { navigation.focusPresentation == .conversationEditing }
    private var isDetailEditing: Bool { isEditing && navigation.detail != .workspace }
    private var isDrawerVisible: Bool { navigation.usesSidebarOverlay && navigation.isSidebarVisible && !isFocused }
    private var isDetailAccessible: Bool { !isDrawerVisible && !workspaceSearchVisible }
    private var isSidebarAccessible: Bool { (navigation.isSidebarVisible || workspaceSearchVisible) && !isEditing }
    private var sidebarLayer: Double {
        guard isSidebarAccessible else { return -1 }
        return workspaceSearchVisible ? IPadShellLayout.focusLayer : 1
    }
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
    private var workspaceRouteInSidebar: Bool { navigation.mainTool != nil }
    private var showsSidebarChat: Bool {
        guard workspaceRouteInSidebar, navigation.section == .workspaces else { return false }
        if case .agentConversation = coordinator.currentScreen { return true }
        return false
    }
    private var workspaceRouteVisible: Bool {
        navigation.detail == .workspace && navigation.pairing == nil
            && (!workspaceRouteInSidebar || showsSidebarChat)
    }
    var body: some View {
        AgentHistoryDrawer(isEnabled: workspaceActionsEnabled && !connectionSwitcherOpen) {
            WorkspaceConnectionSwitcher(
                isPresented: $showingConnectionSwitcher,
                isEnabled: workspaceActionsEnabled,
                onReveal: prepareConnectionSwitcher
            ) {
                shell
            }
        }
        .environment(\.conversationPresentation, .iPad)
        .environment(\.usesDuoContextualRail, usesVerticalBar)
        .environment(\.iPadFocusPresentation, focusPresentation)
        .onGeometryChange(for: CGFloat.self) { $0.safeAreaInsets.top } action: { topSafeArea = $0 }
        .onGeometryChange(for: CGFloat.self) { $0.safeAreaInsets.trailing } action: { trailingSafeArea = $0 }
        .onGeometryChange(for: CGFloat.self) { $0.safeAreaInsets.leading } action: { leadingSafeArea = $0 }
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
            if !layout.usesCompactNavigation, !usesVerticalBar {
                navigationRail
            }
            detailPane
                .padding(paneInsets)
                .zIndex(isDetailEditing ? IPadShellLayout.focusLayer : 0)
            workspaceRoutePane
                .padding(paneInsets)
                .zIndex(isEditing ? IPadShellLayout.focusLayer : (workspaceRouteInSidebar ? Self.sidebarChatLayer : Self.workspaceLayer))
            drawerBackdrop
                .frame(width: layout.contentWidth)
                .offset(x: layout.railLeadingInset)
                .padding(paneInsets)
                .zIndex(1)
            sidebarPane
                .padding(paneInsets)
                // Retained, hidden sidebar containers must not cover detail controls
                // in the accessibility hit-test order.
                .zIndex(sidebarLayer)
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
        .ignoresSafeArea(.container, edges: .vertical)
        .overlayPreferenceValue(DuoContextualRailPreference.self, alignment: railAlignment) { rail in
            if usesVerticalBar, !isFocused {
                rail
                    .frame(width: max(IPadShellLayout.railWidth, railSafeArea + IPadShellLayout.contextualRailOuterInset))
                    .padding(.top, IPadShellLayout.contextualRailTopPadding(for: verticalBarEdge) + bannerInset)
                    .offset(x: verticalBarEdge == .leading ? -railSafeArea : railSafeArea)
            }
        }
        .opacity(width == nil ? 0 : 1)
        .background(IPadShellStyle.background(for: colorScheme).ignoresSafeArea())
        .modifier(WorkspaceActionLauncher(
            isSearching: workspaceSearchVisible,
            isEnabled: width != nil && (layout.usesCompactNavigation || usesVerticalBar) && !isFocused,
            avoidsConversationInput: !usesVerticalBar,
            hostsVerticalBarButton: !usesVerticalBar,
            floatingVerticalBarButtonOffset: usesVerticalBar ? railSafeArea - IPadShellLayout.railWidth / 2 : nil,
            floatingVerticalBarButtonEdge: verticalBarEdge ?? .trailing,
            onWorkspaces: { coordinator.onSelectIPadSection(.workspaces) },
            onAssistant: { coordinator.onSelectIPadSection(.assistant) },
            onPullRequests: { coordinator.onSelectIPadSection(.pullRequests) },
            onCreateWorkspace: createWorkspace,
            onConnections: showConnections
        ))
        .accessibilityAction(.escape) { coordinator.iPadNavigation.setFocusPresentation(.normal) }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { if $0 > 0 { width = $0 } }
        .onGeometryChange(for: CGFloat.self) { min($0.size.width, $0.size.height) } action: { if $0 > 0 { windowShortSide = $0 } }
        .onChange(of: measuredLayout, initial: true) { _, measuredLayout in
            if let measuredLayout {
                coordinator.iPadNavigation.updateLayout(
                    usesOverlay: measuredLayout.usesSidebarOverlay,
                    usesCompactNavigation: measuredLayout.usesCompactNavigation,
                    showsWorkspaceList: showsWorkspaceList
                )
            }
        }
        .onChange(of: sidebarPresentation) { old, new in
            // Layout changes (first measurement, rotation) must not move VoiceOver focus.
            if old.usesOverlay == new.usesOverlay, old.isVisible, !new.isVisible {
                focusedPane = workspaceRouteVisible && !workspaceRouteInSidebar ? .workspace : .detail
            }
        }
        .onChange(of: workspaceSearchVisible) { _, visible in
            if visible { focusedPane = nil }
        }
    }
}

extension IPadShellView {
    private var navigationRail: some View {
        IPadNavigationRail(
            section: navigation.section,
            isSidebarVisible: navigation.isSidebarVisible,
            canUseAssistant: coordinator.canUseAssistant,
            canCreateWorkspace: coordinator.canCreateWorkspace,
            onSelect: coordinator.onSelectIPadSection,
            onCreateWorkspace: createWorkspace
        ) {
            coordinator.iPadNavigation.revealSidebar()
        }
        .blur(radius: isFocused ? IPadShellLayout.focusBlurRadius : 0)
        .allowsHitTesting(!isFocused)
        .accessibilityHidden(isFocused)
        .padding(paneInsets)
        // Keep normal navigation above native pane containers' hit regions.
        .zIndex(isFocused ? 0 : 2)
    }

    private var detailPane: some View {
        let accessible = isDetailAccessible && (!workspaceRouteVisible || workspaceRouteInSidebar) && (!isEditing || isDetailEditing)
        return detail
            .modifier(IPadToolDropTarget(session: session))
            .frame(width: isDetailEditing ? layout.focusedPanelWidth : max(0, layout.contentWidth - layout.detailLeadingInset(sidebarVisible: navigation.isSidebarVisible)))
            .modifier(IPadPaneBounds(
                identifier: workspaceRouteVisible && !workspaceRouteInSidebar ? "ipad.background.panel" : "ipad.detail.panel",
                isAccessible: accessible
            ))
            .padding(.leading, isDetailEditing ? 0 : layout.railLeadingInset + layout.detailLeadingInset(sidebarVisible: navigation.isSidebarVisible))
            .frame(maxWidth: .infinity, alignment: isDetailEditing ? .center : .leading)
            .blur(radius: isFocused && !isDetailEditing ? IPadShellLayout.focusBlurRadius : 0)
            .environment(\.isIPadPaneVisible, accessible)
            .allowsHitTesting(accessible)
            .accessibilityFocused($focusedPane, equals: .detail)
    }

    private var sidebarPane: some View {
        sidebars
            .opacity(showsSidebarChat ? 0 : 1)
            .safeAreaPadding(.bottom, layout.usesCompactNavigation && !workspaceSearchVisible ? AssistantLaunchButton.scrollClearance : 0)
            .frame(width: workspaceSearchVisible ? layout.focusedPanelWidth : layout.sidebarPaneWidth)
            .frame(maxHeight: .infinity)
            .background(IPadShellStyle.background(for: colorScheme))
            .clipShape(sidebarShape)
            .modifier(IPadPaneBounds(
                identifier: showsSidebarChat ? "ipad.background.sidebar.panel" : "ipad.sidebar.panel",
                isAccessible: isSidebarAccessible && !showsSidebarChat
            ))
            .padding(.leading, workspaceSearchVisible ? 0 : layout.sidebarLeadingInset)
            .frame(maxWidth: .infinity, alignment: workspaceSearchVisible ? .center : .leading)
            .blur(radius: isEditing ? IPadShellLayout.focusBlurRadius : 0)
            .opacity(navigation.isSidebarVisible || workspaceSearchVisible ? 1 : 0)
            .allowsHitTesting(isSidebarAccessible && !showsSidebarChat)
            .environment(\.isIPadPaneVisible, isSidebarAccessible && !showsSidebarChat)
    }

    private var workspaceRoutePane: some View {
        let visible = workspaceRouteVisible && (!workspaceRouteInSidebar || navigation.isSidebarVisible || isEditing)
        let accessible = visible && (workspaceRouteInSidebar ? !workspaceSearchVisible : isDetailAccessible)
        let mainWidth = max(0, layout.contentWidth - layout.detailLeadingInset(sidebarVisible: navigation.isSidebarVisible))
        let leading = workspaceRouteInSidebar ? layout.sidebarLeadingInset
            : layout.railLeadingInset + layout.detailLeadingInset(sidebarVisible: navigation.isSidebarVisible)
        return RetainedIPadPane(isVisible: visible, keepsCoveredContentVisible: true) {
            IPadWorkspaceDetailView(session: session)
        }
            .frame(width: isEditing ? layout.focusedPanelWidth : (workspaceRouteInSidebar ? layout.sidebarPaneWidth : mainWidth))
            .frame(maxHeight: .infinity)
            .background(workspaceRouteInSidebar ? IPadSidebarStyle.background(for: colorScheme) : IPadShellStyle.panel(for: colorScheme))
            .clipShape(RoundedRectangle(cornerRadius: IPadShellLayout.cornerRadius))
            .modifier(IPadToolDropTarget(session: session, isEnabled: !workspaceRouteInSidebar))
            .modifier(IPadPaneBounds(
                identifier: workspaceRouteVisible ? (workspaceRouteInSidebar ? "ipad.sidebar.panel" : "ipad.detail.panel") : "ipad.workspace.panel",
                isAccessible: accessible
            ))
            .environment(\.isIPadPaneVisible, accessible)
            .environment(\.iPadFocusPresentation, workspaceRouteInSidebar ? nil : focusPresentation)
            .environment(\.conversationBackgroundColor, workspaceRouteInSidebar ? IPadSidebarStyle.background(for: colorScheme) : nil)
            .environment(
                \.conversationComposerBackgroundColor,
                workspaceRouteInSidebar ? Constants.Conversation.Design.Palette.raisedSurface(for: colorScheme) : nil
            )
            .transformPreference(WorkspaceActionMenuInputTop.self) { inputTop in
                if !accessible { inputTop = nil }
            }
            .opacity(visible ? 1 : 0)
            .allowsHitTesting(accessible)
            .accessibilityFocused($focusedPane, equals: .workspace)
            .blur(radius: workspaceSearchVisible ? IPadShellLayout.focusBlurRadius : 0)
            .padding(.leading, isEditing ? 0 : leading)
            .frame(maxWidth: .infinity, alignment: isEditing ? .center : .leading)
    }

    /// A drawer sits flush against the undimmed shell, so only its trailing edge is rounded.
    private var sidebarShape: UnevenRoundedRectangle {
        let radius = IPadShellLayout.cornerRadius
        let leading = navigation.usesSidebarOverlay && !workspaceSearchVisible ? 0 : radius
        return UnevenRoundedRectangle(
            topLeadingRadius: leading,
            bottomLeadingRadius: leading,
            bottomTrailingRadius: radius,
            topTrailingRadius: radius
        )
    }

    private var detail: some View {
        ZStack {
            if let tool = navigation.mainTool {
                RetainedIPadPane(isVisible: navigation.detail == .workspace && navigation.pairing == nil) {
                    IPadWorkspaceToolView(tool: tool, session: session)
                        .id(tool.id)
                }
            }
            if navigation.hasOpenedAssistant {
                RetainedIPadPane(
                    isVisible: navigation.detail == .assistant && navigation.pairing == nil,
                    keepsCoveredContentVisible: true
                ) {
                    AssistantView(session: session)
                }
            }
            if let pullRequest = coordinator.iPadPullRequest, navigation.detail == .pullRequest, navigation.pairing == nil {
                IPadPullRequestDetail(item: pullRequest, session: session)
                    .id(pullRequest.id)
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
                workspacesSidebar
            }
            if navigation.hasOpenedAssistant {
                RetainedIPadPane(isVisible: navigation.section == .assistant, keepsCoveredContentVisible: true) {
                    IPadAssistantSidebar(
                        session: session,
                        onCollapse: collapseSidebar
                    ) { coordinator.onSelectAssistant(agentId: $0) }
                }
            }
            RetainedIPadPane(isVisible: navigation.section == .pullRequests, keepsCoveredContentVisible: true) {
                IPadPullRequestsSidebar(session: session, onCollapse: collapseSidebar)
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

private extension IPadShellView {
    func prepareConnectionSwitcher() {
        coordinator.iPadNavigation.prepareForConnectionSwitcher(showingWorkspaceList: showsWorkspaceList)
    }
}

/// The workspaces sidebar swaps between the list and the open agent's or note's workspace page.
extension IPadShellView {
    /// A persistent sidebar beside the detail pane; drawers and compact windows keep the list.
    private var workspaceSidebarContent: WorkspaceSidebarContent {
        if let tool = navigation.mainTool { return .workspace(id: tool.workspaceId) }
        return WorkspaceSidebarContent.resolve(
            screen: coordinator.currentScreen,
            isPersistent: width != nil && !layout.usesCompactNavigation && !layout.usesSidebarOverlay && !workspaceSearchVisible
        )
    }

    /// The list stays mounted under a sidebar workspace, keeping its scroll position and search.
    /// The two swap with a crossfade; nothing moves, so a slow first frame cannot read as a jump.
    private var workspacesSidebar: some View {
        ZStack {
            RetainedIPadPane(isVisible: workspaceSidebarContent == .workspaceList) {
                WorkspaceListSidebar(
                    workspaceStore: session.workspaceStore,
                    isSearching: isSearchingWorkspaces,
                    onCreateWorkspace: createWorkspace,
                    onCollapse: collapseSidebar
                )
            }
            if case let .workspace(workspaceId) = workspaceSidebarContent {
                WorkspaceDetailView(
                    workspaceId: workspaceId,
                    session: session,
                    storesCache: coordinator.workspaceDetailStores,
                    sidebar: WorkspaceDetailSidebar(onCollapse: collapseSidebar)
                )
                .id(workspaceId)
                .environment(\.iPadToolDraggingEnabled, !usesVerticalBar)
                .transition(.opacity)
            }
        }
        .clipped()
        .animation(.easeInOut(duration: Constants.Root.screenAnimationDuration), value: workspaceSidebarContent)
    }
}

private struct SidebarPresentation: Equatable {
    let isVisible: Bool
    let usesOverlay: Bool
}

private enum IPadAccessiblePane: Hashable {
    case detail
    case workspace
}
