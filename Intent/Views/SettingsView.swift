import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var coordinator: AppCoordinator
    @Environment(\.colorScheme) var colorScheme
    @AppStorage("appThemePreference") private var themePreference: String = "system"
    @State private var showLogOffConfirmation = false

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.background(for: colorScheme).ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 20) {
                        // Appearance section
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Appearance")
                                .font(.caption.weight(.medium))
                                .foregroundStyle(Theme.mutedForeground(for: colorScheme))
                                .textCase(.uppercase)

                            VStack(spacing: 0) {
                                Picker("Theme", selection: $themePreference) {
                                    Text("Light").tag("light")
                                    Text("Dark").tag("dark")
                                    Text("System").tag("system")
                                }
                                .pickerStyle(.segmented)
                                .padding(16)
                            }
                            .background(Theme.card(for: colorScheme))
                            .cornerRadius(12)
                            .overlay(
                                RoundedRectangle(cornerRadius: 12)
                                    .stroke(Theme.border(for: colorScheme), lineWidth: 1)
                            )
                        }

                        // Connected server card
                        if let pairing = PersistenceManager.shared.loadPairing() {
                            VStack(alignment: .leading, spacing: 12) {
                                Text("Connected to")
                                    .font(.caption.weight(.medium))
                                    .foregroundStyle(Theme.mutedForeground(for: colorScheme))
                                    .textCase(.uppercase)

                                HStack(spacing: 12) {
                                    Image(systemName: "desktopcomputer")
                                        .font(.title2)
                                        .foregroundStyle(Theme.primary(for: colorScheme))

                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(pairing.server.name)
                                            .font(.body.weight(.medium))
                                            .foregroundStyle(Theme.foreground(for: colorScheme))
                                        Text(verbatim: "\(pairing.server.hosts.joined(separator: ", ")):\(pairing.server.port)")
                                            .font(.caption)
                                            .foregroundStyle(Theme.mutedForeground(for: colorScheme))
                                    }

                                    Spacer()

                                    HStack(spacing: 4) {
                                        Circle()
                                            .fill(.green)
                                            .frame(width: 8, height: 8)
                                        Text("Connected")
                                            .font(.caption)
                                            .foregroundStyle(.green)
                                    }
                                }
                            }
                            .padding(16)
                            .background(Theme.card(for: colorScheme))
                            .cornerRadius(12)
                            .overlay(
                                RoundedRectangle(cornerRadius: 12)
                                    .stroke(Theme.border(for: colorScheme), lineWidth: 1)
                            )
                        }

                        // Account section
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Account")
                                .font(.caption.weight(.medium))
                                .foregroundStyle(Theme.mutedForeground(for: colorScheme))
                                .textCase(.uppercase)

                            Button(role: .destructive) {
                                showLogOffConfirmation = true
                            } label: {
                                HStack {
                                    Image(systemName: "rectangle.portrait.and.arrow.right")
                                    Text("Log Off")
                                    Spacer()
                                }
                                .padding(16)
                                .background(Theme.card(for: colorScheme))
                                .cornerRadius(12)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 12)
                                        .stroke(Theme.border(for: colorScheme), lineWidth: 1)
                                )
                            }
                        }

                        Spacer()
                    }
                    .padding(20)
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button {
                        coordinator.onSettingsBack()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "chevron.left")
                            Text("Back")
                        }
                    }
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
        .environmentObject(AppCoordinator())
}

#Preview("Settings - Dark") {
    SettingsView()
        .environmentObject(AppCoordinator())
        .preferredColorScheme(.dark)
}

