import SwiftUI

struct SettingsView: View {
    @Environment(AppCoordinator.self) var coordinator
    @Environment(\.colorScheme) var colorScheme
    @AppStorage("appThemePreference") private var themePreference: String = "system"
    @State private var showLogOffConfirmation = false

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.background(for: colorScheme).ignoresSafeArea()

                ScrollView {
                    VStack(spacing: Constants.Settings.contentSpacing) {
                        // Appearance section
                        VStack(alignment: .leading, spacing: Constants.Settings.sectionSpacing) {
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
                                .padding(Constants.Settings.cardPadding)
                            }
                            .background(Theme.card(for: colorScheme))
                            .clipShape(.rect(cornerRadius: Constants.Settings.cardCornerRadius))
                            .overlay(
                                RoundedRectangle(cornerRadius: Constants.Settings.cardCornerRadius)
                                    .stroke(Theme.border(for: colorScheme), lineWidth: Constants.Settings.cardBorderWidth)
                            )
                        }

                        // Connected server card
                        if let connection = PersistenceManager.shared.activeConnection() {
                            VStack(alignment: .leading, spacing: Constants.Settings.sectionSpacing) {
                                Text("Connected to")
                                    .font(.caption.weight(.medium))
                                    .foregroundStyle(Theme.mutedForeground(for: colorScheme))
                                    .textCase(.uppercase)

                                HStack(spacing: Constants.Settings.connectionRowSpacing) {
                                    Image(systemName: "desktopcomputer")
                                        .font(.title2)
                                        .foregroundStyle(Theme.primary(for: colorScheme))

                                    VStack(alignment: .leading, spacing: Constants.Settings.connectionTextSpacing) {
                                        Text(connection.displayName)
                                            .font(.body.weight(.medium))
                                            .foregroundStyle(Theme.foreground(for: colorScheme))
                                        Text(verbatim: "\(connection.server.hosts.joined(separator: ", ")):\(connection.server.port)")
                                            .font(.caption)
                                            .foregroundStyle(Theme.mutedForeground(for: colorScheme))
                                    }

                                    Spacer()

                                    HStack(spacing: Constants.Settings.statusSpacing) {
                                        Circle()
                                            .fill(.green)
                                            .frame(width: Constants.Settings.statusDotSize,
                                                   height: Constants.Settings.statusDotSize)
                                        Text("Connected")
                                            .font(.caption)
                                            .foregroundStyle(.green)
                                    }
                                }
                            }
                            .padding(Constants.Settings.cardPadding)
                            .background(Theme.card(for: colorScheme))
                            .clipShape(.rect(cornerRadius: Constants.Settings.cardCornerRadius))
                            .overlay(
                                RoundedRectangle(cornerRadius: Constants.Settings.cardCornerRadius)
                                    .stroke(Theme.border(for: colorScheme), lineWidth: Constants.Settings.cardBorderWidth)
                            )
                        }

                        // Account section
                        VStack(alignment: .leading, spacing: Constants.Settings.sectionSpacing) {
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
                                .padding(Constants.Settings.cardPadding)
                                .background(Theme.card(for: colorScheme))
                                .clipShape(.rect(cornerRadius: Constants.Settings.cardCornerRadius))
                                .overlay(
                                    RoundedRectangle(cornerRadius: Constants.Settings.cardCornerRadius)
                                        .stroke(Theme.border(for: colorScheme), lineWidth: Constants.Settings.cardBorderWidth)
                                )
                            }
                        }

                        Spacer()
                    }
                    .padding(Constants.Settings.contentPadding)
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button {
                        coordinator.onSettingsBack()
                    } label: {
                        HStack(spacing: Constants.Settings.backButtonSpacing) {
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
        .environment(AppCoordinator())
}

#Preview("Settings - Dark") {
    SettingsView()
        .environment(AppCoordinator())
        .preferredColorScheme(.dark)
}

