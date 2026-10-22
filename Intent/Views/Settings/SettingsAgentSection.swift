import SwiftUI

struct SettingsAgentSection: View {
    @Environment(AppCoordinator.self) private var coordinator
    @Environment(BackendSession.self) private var session
    @Environment(\.colorScheme) private var colorScheme
    @State private var showingInstructions = false

    var body: some View {
        SettingsSection(title: "AGENTS") {
            VStack(spacing: 0) {
                Button { showingInstructions = true } label: {
                    SettingsActionLabel(title: "Global instructions", image: .file)
                }
                .accessibilityIdentifier("settings.instructions")
                Divider()
                NavigationLink {
                    ProvidersSettingsView(connectionManager: session.connection, hostName: hostName)
                        .environment(\.colorScheme, colorScheme)
                } label: {
                    SettingsActionLabel(title: "Providers", image: .settings2)
                }
                .accessibilityIdentifier("settings.providers")
            }
            .background(SettingsStyle.card(for: colorScheme), in: .rect(cornerRadius: SettingsStyle.cardRadius))
        }
        .sheet(isPresented: $showingInstructions) {
            GlobalInstructionsSettingsView(connection: session.connection, hostName: hostName)
                .preferredColorScheme(colorScheme)
        }
    }

    private var hostName: String {
        coordinator.savedConnections.first { $0.id == session.backendID?.connectionID }?.displayName ?? "this host"
    }
}
