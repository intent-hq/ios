import SwiftUI

/// Home-screen actions float above the list without resetting its scroll position.
struct WorkspaceActionLauncher: ViewModifier {
    let isSearching: Bool
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
        static let shadeOpacity = 0.6
        static let duration = 0.2
    }

    func body(content: Content) -> some View {
        content
            .scrollDisabled(isOpen)
            .blur(radius: isOpen && !reduceTransparency ? Layout.blurRadius : 0)
            .allowsHitTesting(!isOpen)
            .accessibilityHidden(isOpen)
            .overlay {
                if isOpen {
                    actionOverlay
                        .transition(.opacity)
                } else if !isSearching {
                    VStack {
                        Spacer()
                        HStack {
                            Spacer()
                            AssistantLaunchButton {
                                connectionCount = PersistenceManager.shared.loadConnections().count
                                isOpen = true
                            }
                        }
                    }
                }
            }
            .animation(reduceMotion ? nil : .easeInOut(duration: Layout.duration), value: isOpen)
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

    private var actionOverlay: some View {
        ZStack(alignment: .bottom) {
            Theme.background(for: colorScheme)
                .opacity(reduceTransparency ? 1 : Layout.shadeOpacity)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { isOpen = false }
                .accessibilityHidden(true)
            HomeActionTiles(
                connectionCount: connectionCount,
                appearance: appearanceTitle,
                onSelect: select
            ) { isOpen = false }
        }
        .environment(\.refresh, nil)
        .accessibilityAddTraits(.isModal)
        .accessibilityAction(.escape) { isOpen = false }
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
        case .logOff: break
        }
    }
}
