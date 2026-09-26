import SwiftUI

struct SettingsView: View {
    @Environment(AppCoordinator.self) var coordinator
    @Environment(BackendSession.self) var session
    @Environment(\.colorScheme) var colorScheme
    @AppStorage("appThemePreference") private var themePreference: String = "system"
    @State private var showLogOffConfirmation = false

    var body: some View {
        NavigationStack {
            settingsSurface
                .onAppear { coordinator.refreshSyncedBackends() }
                .refreshable { coordinator.refreshSyncedBackends() }
                .toolbar(.hidden, for: .navigationBar)
                .alert("Log Off?", isPresented: $showLogOffConfirmation) {
                    Button("Cancel", role: .cancel) {}
                    Button("Log Off", role: .destructive) { coordinator.onLogOff() }
                } message: {
                    Text("Are you sure? You'll need to pair again to reconnect.")
                }
        }
    }

    private var settingsSurface: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SettingsStyle.sectionSpacing) {
                SettingsHeader(onClose: coordinator.onSettingsBack)
                    .padding(.bottom, SettingsStyle.headingSpacing - SettingsStyle.sectionSpacing)
                SettingsSection(title: "APPEARANCE") {
                    SettingsAppearanceSelector(selection: $themePreference)
                }
                .padding(.bottom, SettingsStyle.appearanceBottomSpacing)
                SettingsConnectionsSection(
                    connections: coordinator.savedConnections,
                    windowConnectionID: coordinator.windowConnectionID,
                    status: session.connection.connectionState,
                    mismatches: session.connection.certMismatches,
                    onSelect: selectConnection
                )
                SettingsPairingSection()
                SettingsSupportSection()
            }
            .padding(SettingsStyle.contentMargin)
            .frame(maxWidth: SettingsStyle.maximumContentWidth)
            .frame(maxWidth: .infinity)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            logOffButton
                .padding(SettingsStyle.contentMargin)
                .frame(maxWidth: SettingsStyle.maximumContentWidth)
                .frame(maxWidth: .infinity)
                .background(SettingsStyle.surface(for: colorScheme))
        }
        .buttonStyle(.plain)
        .foregroundStyle(SettingsStyle.foreground(for: colorScheme))
        .clipShape(UnevenRoundedRectangle(
            topLeadingRadius: SettingsStyle.surfaceRadius,
            topTrailingRadius: SettingsStyle.surfaceRadius
        ))
        .background {
            UnevenRoundedRectangle(
                topLeadingRadius: SettingsStyle.surfaceRadius,
                topTrailingRadius: SettingsStyle.surfaceRadius
            )
            .fill(SettingsStyle.surface(for: colorScheme))
            .ignoresSafeArea(edges: .bottom)
        }
        // Keep the real system status bar and its light/dark contrast. Do not
        // draw the status bar or force the rest of Settings into dark mode.
        .background((colorScheme == .dark ? SettingsStyle.charcoal : SettingsStyle.lightChrome).ignoresSafeArea())
    }

    private func selectConnection(_ id: UUID) {
        if id == coordinator.windowConnectionID {
            coordinator.onSettingsBack()
        } else {
            coordinator.onSwitchConnection(id: id)
        }
    }

    private var logOffButton: some View {
        Button { showLogOffConfirmation = true } label: {
            Label("Log Off", systemImage: "rectangle.portrait.and.arrow.right")
                .font(.callout.weight(.medium))
                .fixedSize(horizontal: false, vertical: true)
                .padding(.vertical, SettingsStyle.rowVerticalPadding)
                .frame(maxWidth: .infinity, minHeight: SettingsStyle.rowHeight)
                .foregroundStyle(SettingsStyle.lightForeground)
                .background(SettingsStyle.accent, in: .rect(cornerRadius: SettingsStyle.cardRadius))
                .contentShape(.rect(cornerRadius: SettingsStyle.cardRadius))
        }
    }
}

#Preview("Settings") {
    let session = BackendSessionRegistry.shared.makePairingSession()
    SettingsView()
        .environment(session)
        .environment(session.makeCoordinator())
}

#Preview("Settings - Dark") {
    let session = BackendSessionRegistry.shared.makePairingSession()
    SettingsView()
        .environment(session)
        .environment(session.makeCoordinator())
        .preferredColorScheme(.dark)
}
