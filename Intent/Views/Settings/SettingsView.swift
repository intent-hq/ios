import SwiftUI

struct SettingsView: View {
    @Environment(AppCoordinator.self) var coordinator
    @Environment(BackendSession.self) var session
    @Environment(\.colorScheme) var colorScheme
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @AppStorage("appThemePreference") private var themePreference: String = "system"
    @State private var showLogOffConfirmation = false

    var body: some View {
        NavigationStack {
            settingsForm
                .navigationTitle("Settings")
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { coordinator.onSettingsBack() }
                    }
                }
                .alert("Log Off?", isPresented: $showLogOffConfirmation) {
                    Button("Cancel", role: .cancel) {}
                    Button("Log Off", role: .destructive) { coordinator.onLogOff() }
                } message: {
                    Text("Are you sure? You'll need to pair again to reconnect.")
                }
        }
    }

    private var settingsForm: some View {
        Form {
            appearanceSection
            connectionSection
            accountSection
            aboutSection
        }
        .scrollContentBackground(.hidden)
        .background(Theme.background(for: colorScheme))
    }

    private var appearanceSection: some View {
        Section("Appearance") {
            Picker("Theme", selection: $themePreference) {
                Text("Light").tag("light")
                Text("Dark").tag("dark")
                Text("System").tag("system")
            }
            .pickerStyle(.segmented)
        }
    }

    @ViewBuilder
    private var connectionSection: some View {
        if let connection = coordinator.windowConnection {
            Section("Connected To") {
                connectionSummaryLayout {
                    connectionIdentity(connection)
                    HStack(spacing: Constants.Settings.statusSpacing) {
                        Circle()
                            .fill(.green)
                            .frame(
                                width: Constants.Settings.statusDotSize,
                                height: Constants.Settings.statusDotSize
                            )
                        Text("Connected").font(.caption)
                    }
                }
                if !session.connection.certMismatches.isEmpty {
                    CertMismatchListView(mismatches: session.connection.certMismatches)
                }
            }
        }
    }

    private func connectionIdentity(_ connection: StoredConnection) -> some View {
        HStack(spacing: Constants.Settings.connectionRowSpacing) {
            Image(systemName: "desktopcomputer")
                .font(.title2)
                .foregroundStyle(Theme.primary(for: colorScheme))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Constants.Settings.connectionTextSpacing) {
                Text(connection.displayName).font(.body.weight(.medium))
                Text(verbatim: "\(connection.server.hosts.joined(separator: ", ")):\(connection.server.port)")
                    .font(.caption)
                    .foregroundStyle(Theme.mutedForeground(
                        for: colorScheme,
                        contrast: colorSchemeContrast
                    ))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var accountSection: some View {
        Section("Account") {
            Button(role: .destructive) { showLogOffConfirmation = true } label: {
                Label("Log Off", systemImage: "rectangle.portrait.and.arrow.right")
            }
        }
    }

    private var aboutSection: some View {
        Section("About") {
            NavigationLink { AcknowledgementsView() } label: {
                Label("Acknowledgements", systemImage: "doc.text")
            }
        }
    }

    private var connectionSummaryLayout: AnyLayout {
        if Self.stacksConnectionSummary(for: dynamicTypeSize) {
            AnyLayout(VStackLayout(alignment: .leading, spacing: Constants.Settings.connectionRowSpacing))
        } else {
            AnyLayout(HStackLayout(spacing: Constants.Settings.connectionRowSpacing))
        }
    }

    static func stacksConnectionSummary(for dynamicTypeSize: DynamicTypeSize) -> Bool {
        dynamicTypeSize.isAccessibilitySize
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
