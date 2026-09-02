import SwiftUI

struct SettingsView: View {
    @Environment(AppCoordinator.self) var coordinator
    @Environment(ConnectionManager.self) var connectionManager
    @Environment(\.colorScheme) var colorScheme
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @AppStorage("appThemePreference") private var themePreference: String = "system"
    @State private var showLogOffConfirmation = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Appearance") {
                    Picker("Theme", selection: $themePreference) {
                        Text("Light").tag("light")
                        Text("Dark").tag("dark")
                        Text("System").tag("system")
                    }
                    .pickerStyle(.segmented)
                }

                if let connection = PersistenceManager.shared.activeConnection() {
                    Section("Connected To") {
                        HStack(spacing: Constants.Settings.connectionRowSpacing) {
                            Image(systemName: "desktopcomputer")
                                .font(.title2)
                                .foregroundStyle(Theme.primary(for: colorScheme))

                            VStack(alignment: .leading, spacing: Constants.Settings.connectionTextSpacing) {
                                Text(connection.displayName)
                                    .font(.body.weight(.medium))
                                Text(verbatim: "\(connection.server.hosts.joined(separator: ", ")):\(connection.server.port)")
                                    .font(.caption)
                                    .foregroundStyle(Theme.mutedForeground(
                                        for: colorScheme, contrast: colorSchemeContrast))
                            }

                            Spacer()

                            HStack(spacing: Constants.Settings.statusSpacing) {
                                Circle()
                                    .fill(.green)
                                    .frame(width: Constants.Settings.statusDotSize,
                                           height: Constants.Settings.statusDotSize)
                                Text("Connected")
                                    .font(.caption)
                            }
                        }

                        if !connectionManager.certMismatches.isEmpty {
                            CertMismatchListView(mismatches: connectionManager.certMismatches)
                        }
                    }
                }

                Section("Account") {
                    Button(role: .destructive) {
                        showLogOffConfirmation = true
                    } label: {
                        Label("Log Off", systemImage: "rectangle.portrait.and.arrow.right")
                    }
                }

                Section("About") {
                    NavigationLink {
                        AcknowledgementsView()
                    } label: {
                        Label("Acknowledgements", systemImage: "doc.text")
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.background(for: colorScheme))
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { coordinator.onSettingsBack() }
                }
            }
            .alert("Log Off?", isPresented: $showLogOffConfirmation) {
                Button("Cancel", role: .cancel) {}
                Button("Log Off", role: .destructive) {
                    coordinator.onLogOff()
                }
            } message: {
                Text("Are you sure? You'll need to pair again to reconnect.")
            }
        }
    }
}

#Preview("Settings") {
    SettingsView()
        .environment(AppCoordinator())
        .environment(ConnectionManager.shared)
}

#Preview("Settings - Dark") {
    SettingsView()
        .environment(AppCoordinator())
        .environment(ConnectionManager.shared)
        .preferredColorScheme(.dark)
}

