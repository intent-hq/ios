import SwiftUI

/// Actions float above the navigation content without resetting its scroll position.
struct WorkspaceActionLauncher: ViewModifier {
    let isSearching: Bool
    var alignment: HorizontalAlignment = .trailing
    let onCreateWorkspace: () -> Void
    let onConnections: () -> Void
    @Environment(AppCoordinator.self) private var coordinator
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @AppStorage("appThemePreference") private var themePreference = "system"
    @State private var isOpen = false
    @State private var connectionCount = 0
    @State private var destination: HomeActionDestination?
    @State private var confirmingLogOff = false

    private enum Layout {
        static let blurRadius: CGFloat = 16
        static let lightShadeOpacity = 0.72
        static let darkShadeOpacity = 0.6
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
            .overlayPreferenceValue(WorkspaceActionMenuComposerBounds.self) { composerAnchor in
                // Resolve the composer anchor in the window overlay's coordinate space.
                // swiftlint:disable:next geometry_reader_usage
                GeometryReader { proxy in
                    let bottomInset = composerAnchor.map { max(0, proxy.size.height - proxy[$0].minY) } ?? 0
                    actionOverlay(bottomInset: bottomInset)
                }
            }
            .animation(
                reduceMotion ? nil : .spring(response: Layout.springResponse, dampingFraction: Layout.springDamping),
                value: isOpen
            )
            .sheet(item: $destination) { destination in
                HomeActionSettingsView(destination: destination)
            }
            .alert("Log Off?", isPresented: $confirmingLogOff) {
                Button("Cancel", role: .cancel) {}
                Button("Log Off", role: .destructive) {
                    isOpen = false
                    coordinator.onLogOff()
                }
            } message: {
                Text("Are you sure? You'll need to pair again to reconnect.")
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
                (colorScheme == .light ? Color.black : Theme.background(for: colorScheme))
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
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(isOpen ? .isModal : [])
        .accessibilityAction(.escape) { isOpen = false }
    }

    private var backdropOpacity: Double {
        if reduceTransparency { return 1 }
        return colorScheme == .light ? Layout.lightShadeOpacity : Layout.darkShadeOpacity
    }

    private var actionControls: some View {
        VStack(alignment: alignment, spacing: Layout.footerSpacing) {
            Spacer(minLength: 0)
            if isOpen {
                HomeActionTiles(connectionCount: connectionCount, appearance: appearanceTitle, onSelect: select)
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
        // Cancellation of Log Off returns to the menu; destinations dismiss it.
        if action == .logOff {
            confirmingLogOff = true
            return
        }
        isOpen = false
        switch action {
        case .assistant: coordinator.onSelectAssistant()
        case .workspace: onCreateWorkspace()
        case .connections: onConnections()
        case .appearance: destination = .appearance
        case .acknowledgements: destination = .acknowledgements
        case .settings: coordinator.onOpenSettings()
        case .logOff: break
        }
    }
}

struct WorkspaceActionMenuComposerBounds: PreferenceKey {
    nonisolated static var defaultValue: Anchor<CGRect>? { nil }

    nonisolated static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
        value = nextValue() ?? value
    }
}
