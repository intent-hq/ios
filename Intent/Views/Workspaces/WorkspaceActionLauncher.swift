import SwiftUI

/// Actions float above the navigation content without resetting its scroll position.
struct WorkspaceActionLauncher: ViewModifier {
    let isSearching: Bool
    var alignment: HorizontalAlignment = .trailing
    var avoidsConversationInput = true
    var hostsVerticalBarButton = true
    let onCreateWorkspace: () -> Void
    let onConnections: () -> Void
    @Environment(AppCoordinator.self) private var coordinator
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.workspaceUsesVerticalBar) private var usesVerticalBar
    @AppStorage("appThemePreference") private var themePreference = "system"
    @State private var isOpen = false
    @State private var connectionCount = 0
    @State private var overlayBottom: CGFloat = 0

    private enum Layout {
        static let blurRadius: CGFloat = 15
        static let shadeOpacity = 0.8
        // The shared light/dark home-menu fade in IOS Working.
        // swiftlint:disable:next no_magic_numbers
        static let shade = Color(.sRGB, red: 26 / 255, green: 26 / 255, blue: 25 / 255)
        static let springResponse = 0.35
        static let springDamping = 0.85
        static let footerSpacing: CGFloat = 23
        static let menuBottomInset: CGFloat = 24
        static let launcherBottomInset: CGFloat = 12
        static let tileEntranceOffset: CGFloat = 20
    }

    func body(content: Content) -> some View {
        if usesVerticalBar {
            floatingMenu(content: content)
                .onChange(of: isOpen) { _, open in
                    if open { connectionCount = PersistenceManager.shared.loadConnections().count }
                }
                .modifier(WorkspaceActionLauncherToolbar(isEnabled: hostsVerticalBarButton && !isSearching))
                .environment(\.workspaceActionMenuPresented, $isOpen)
        } else {
            floatingMenu(content: content)
        }
    }

    // Keep the original modifier chain and ordering on devices without a vertical bar.
    private func floatingMenu(content: Content) -> some View {
        content
            .scrollDisabled(isOpen)
            .blur(radius: isOpen && !reduceTransparency ? Layout.blurRadius : 0)
            .allowsHitTesting(!isOpen)
            .accessibilityHidden(isOpen)
            .overlayPreferenceValue(WorkspaceActionMenuInputTop.self) { inputTop in
                let bottomInset = avoidsConversationInput ? inputTop.map { max(0, overlayBottom - $0) } ?? 0 : 0
                // Keep the overlay's measured extent independent of its padded controls.
                Color.clear
                    .allowsHitTesting(false)
                    .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).maxY } action: { overlayBottom = $0 }
                    .overlay { actionOverlay(bottomInset: bottomInset) }
            }
            .animation(
                reduceMotion ? nil : .spring(response: Layout.springResponse, dampingFraction: Layout.springDamping),
                value: isOpen
            )
            .onChange(of: isSearching) { _, searching in
                if searching { isOpen = false }
            }
            .onChange(of: coordinator.selectedWorkspaceId) { _, _ in isOpen = false }
            .onDisappear { isOpen = false }
    }

    private func actionOverlay(bottomInset: CGFloat) -> some View {
        ZStack(alignment: Alignment(horizontal: alignment, vertical: .bottom)) {
            if isOpen {
                Layout.shade
                    .opacity(backdropOpacity)
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture { isOpen = false }
                    .accessibilityHidden(true)
                    .transition(.opacity)
            }
            if !isSearching {
                actionControls
                    .padding(.bottom, bottomInset + (isOpen && bottomInset == 0 ? Layout.menuBottomInset : Layout.launcherBottomInset))
                    .ignoresSafeArea(.container, edges: isOpen && bottomInset == 0 ? .bottom : [])
                    .animation(
                        reduceMotion ? nil : .spring(response: Layout.springResponse, dampingFraction: Layout.springDamping),
                        value: bottomInset
                    )
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(isOpen ? .isModal : [])
        .accessibilityAction(.escape) { isOpen = false }
    }

    private var backdropOpacity: Double {
        if reduceTransparency { return 1 }
        return Layout.shadeOpacity
    }

    private var actionControls: some View {
        VStack(alignment: alignment, spacing: Layout.footerSpacing) {
            Spacer(minLength: 0)
            if isOpen {
                HomeActionTiles(
                    connectionCount: connectionCount,
                    appearance: appearanceTitle,
                    themePreference: themePreference,
                    onSelect: select,
                    allowsWorkspaceCreation: coordinator.canCreateWorkspace,
                    allowsAssistant: coordinator.canUseAssistant
                )
                    .transition(reduceMotion ? .opacity : .offset(y: Layout.tileEntranceOffset).combined(with: .opacity))
            }
            if usesVerticalBar {
                // Keep the close control inside the modal overlay's accessibility boundary.
                if isOpen {
                    AssistantLaunchButton(isOpen: isOpen) { isOpen.toggle() }
                }
            } else {
                AssistantLaunchButton(isOpen: isOpen) {
                    if !isOpen { connectionCount = PersistenceManager.shared.loadConnections().count }
                    isOpen.toggle()
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: Alignment(horizontal: alignment, vertical: .bottom))
    }

    private var appearanceTitle: String {
        switch themePreference {
        case "light": "Light Mode"
        case "dark": "Dark Mode"
        default: "System"
        }
    }

    private func select(_ action: HomeActionTiles.Action) {
        if action == .appearance {
            themePreference = ["light": "dark", "dark": "system"][themePreference] ?? "light"
            return
        }
        isOpen = false
        switch action {
        case .assistant: coordinator.onSelectAssistant()
        case .workspace: if coordinator.canCreateWorkspace { onCreateWorkspace() }
        case .connections: onConnections()
        case .settings: coordinator.onOpenSettings()
        case .appearance: break
        }
    }
}

/// Pushed compact Duo screens need a launcher after the Workspaces list leaves the screen.
struct WorkspaceCompactActionLauncher: ViewModifier {
    let showsWorkspaceDetail: Bool
    @Environment(\.workspaceUsesVerticalBar) private var usesVerticalBar
    @Environment(AppCoordinator.self) private var coordinator
    @Environment(BackendSession.self) private var session
    @State private var showingCreateWorkspace = false
    @State private var showingConnections = false

    func body(content: Content) -> some View {
        if usesVerticalBar {
            content
                .modifier(WorkspaceActionLauncher(
                    isSearching: !showsWorkspaceDetail,
                    hostsVerticalBarButton: false,
                    onCreateWorkspace: { showingCreateWorkspace = true },
                    onConnections: { showingConnections = true }
                ))
                .onChange(of: coordinator.shouldDismissWorkspaceCreation) { _, shouldDismiss in
                    if shouldDismiss { showingCreateWorkspace = false }
                }
                .sheet(isPresented: $showingCreateWorkspace) {
                    CreateWorkspaceView(session: session, coordinator: coordinator)
                        .environment(coordinator)
                }
                .sheet(isPresented: $showingConnections) {
                    ConnectionsView()
                        .environment(coordinator)
                }
        } else {
            content
        }
    }
}

/// Navigation content owns the toolbar; its outer launcher still owns the menu overlay.
struct WorkspaceActionLauncherToolbar: ViewModifier {
    var isEnabled = true
    @Environment(\.workspaceUsesVerticalBar) private var usesVerticalBar
    @Environment(\.workspaceActionMenuPresented) private var menuPresented

    func body(content: Content) -> some View {
        // Gate the modifier itself: older SDKs cannot build an empty toolbar closure.
        #if os(iOS) && canImport(SwiftUI, _version: 8.0.85)
        if #available(iOS 27.1, *), usesVerticalBar {
            content.toolbar {
                if isEnabled, let menuPresented, !menuPresented.wrappedValue {
                    ToolbarSpacer(.flexible, placement: .bottomBar)
                        .axisBehavior(.verticalPreferred)
                    ToolbarItem(placement: .bottomBar) {
                        AssistantLaunchButton(isOpen: false, isInVerticalBar: true) {
                            menuPresented.wrappedValue = true
                        }
                    }
                    .axisBehavior(.verticalPreferred)
                    .sharedBackgroundVisibility(.hidden)
                    .contentMarginsRemoved()
                }
            }
        } else {
            content
        }
        #else
        content
        #endif
    }
}

/// The active input's top edge in the same global coordinate space as the launcher overlay.
struct WorkspaceActionMenuInputTop: PreferenceKey {
    nonisolated static var defaultValue: CGFloat? { nil }

    nonisolated static func reduce(value: inout CGFloat?, nextValue: () -> CGFloat?) {
        value = nextValue() ?? value
    }
}

extension EnvironmentValues {
    @Entry var workspaceActionMenuPresented: Binding<Bool>?

    var workspaceUsesVerticalBar: Bool {
        #if os(iOS) && canImport(SwiftUI, _version: 8.0.85)
        if #available(iOS 27.1, *) { return self[WorkspaceVerticalBarKey.self] }
        #endif
        return false
    }
}

#if os(iOS) && canImport(SwiftUI, _version: 8.0.85)
@available(iOS 27.1, *)
private struct WorkspaceVerticalBarKey: UITraitBridgedEnvironmentKey {
    nonisolated static let defaultValue = false

    static func read(from traitCollection: UITraitCollection) -> Bool {
        traitCollection.userInterfaceIdiom == .phone && traitCollection.verticalBarEdge == .trailing
    }

    // This observes a system-owned trait; the app must not override its placement.
    static func write(to _: inout any UIMutableTraits, value _: Bool) {}
}
#endif
