import SwiftUI

/// Actions float above the navigation content without resetting its scroll position.
struct WorkspaceActionLauncher: ViewModifier {
    let isSearching: Bool
    var alignment: HorizontalAlignment = .trailing
    var avoidsConversationInput = true
    let onCreateWorkspace: () -> Void
    let onConnections: () -> Void
    @Environment(AppCoordinator.self) private var coordinator
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @AppStorage("appThemePreference") private var themePreference = "system"
    @State private var isOpen = false
    @State private var connectionCount = 0
    @State private var showingAcknowledgements = false

    private enum Layout {
        static let blurRadius: CGFloat = 15
        static let shadeOpacity = 0.8
        // The shared light/dark home-menu fade in IOS Working.
        // swiftlint:disable:next no_magic_numbers
        static let shade = Color(.sRGB, red: 26 / 255, green: 26 / 255, blue: 25 / 255)
        static let springResponse = 0.35
        static let springDamping = 0.85
        static let footerSpacing: CGFloat = 20
        static let tileEntranceOffset: CGFloat = 20
    }

    func body(content: Content) -> some View {
        content
            .scrollDisabled(isOpen)
            .blur(radius: isOpen && !reduceTransparency ? Layout.blurRadius : 0)
            .allowsHitTesting(!isOpen)
            .accessibilityHidden(isOpen)
            .overlayPreferenceValue(WorkspaceActionMenuInputBounds.self) { inputAnchor in
                // Resolve the active input anchor in the window overlay's coordinate space.
                // swiftlint:disable:next geometry_reader_usage
                GeometryReader { proxy in
                    let activeAnchor = avoidsConversationInput ? inputAnchor : nil
                    let bottomInset = activeAnchor.map { max(0, proxy.size.height - proxy[$0].minY) } ?? 0
                    actionOverlay(bottomInset: bottomInset)
                }
            }
            .animation(
                reduceMotion ? nil : .spring(response: Layout.springResponse, dampingFraction: Layout.springDamping),
                value: isOpen
            )
            .sheet(isPresented: $showingAcknowledgements) {
                HomeActionSettingsView()
            }
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
                    .padding(.bottom, bottomInset)
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
            AssistantLaunchButton(isOpen: isOpen) {
                if !isOpen { connectionCount = PersistenceManager.shared.loadConnections().count }
                isOpen.toggle()
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
        case .acknowledgements: showingAcknowledgements = true
        case .settings: coordinator.onOpenSettings()
        case .appearance: break
        }
    }
}

struct WorkspaceActionMenuInputBounds: PreferenceKey {
    nonisolated static var defaultValue: Anchor<CGRect>? { nil }

    nonisolated static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
        value = nextValue() ?? value
    }
}
