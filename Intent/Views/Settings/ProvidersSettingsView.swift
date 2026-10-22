import SwiftUI

struct ProvidersSettingsView: View {
    @Environment(BackendSession.self) private var session
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast
    @State private var store: ProviderManagementStore
    @State private var providerToTest: ProviderManagementStore.Provider?
    private let connectionManager: ConnectionManagerRouting
    private let hostName: String

    init(connectionManager: ConnectionManagerRouting, hostName: String = "Connected host") {
        self.connectionManager = connectionManager
        self.hostName = hostName
        _store = State(initialValue: ProviderManagementStore(connectionManager: connectionManager))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SettingsStyle.sectionSpacing) {
                hostSection
                if let error = store.errorMessage {
                    VStack(alignment: .leading, spacing: SettingsStyle.metadataSpacing) {
                        Text(error).interFont(Constants.Typography.bodyS)
                        Button("Retry loading") { Task { await store.load() } }
                            .accessibilityIdentifier("settings.providers.retry")
                            .disabled(store.isBusy)
                    }
                    .accessibilityIdentifier("settings.providers.error")
                }
                if store.isBusy {
                    ProgressView("Checking host providers…")
                        .accessibilityIdentifier("settings.providers.loading")
                }
                if store.hasLoaded, store.providers.isEmpty {
                    Text("This host has no visible providers.")
                        .interFont(Constants.Typography.bodyS)
                }
                ForEach(store.providers) { providerCard($0) }
            }
            .padding(SettingsStyle.contentMargin)
            .frame(maxWidth: SettingsStyle.maximumContentWidth, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(SettingsStyle.surface(for: colorScheme).ignoresSafeArea())
        .foregroundStyle(SettingsStyle.foreground(for: colorScheme))
        .buttonStyle(IntentContentButtonStyle())
        .navigationTitle("Providers")
        .toolbarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .intentNavigationBackButton()
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Refresh", systemImage: "arrow.clockwise") { Task { await store.load() } }
                    .disabled(store.isBusy)
                    .accessibilityIdentifier("settings.providers.refresh")
            }
        }
        .task { await store.load() }
        .onReceive(connectionManager.connectionStatePublisher.dropFirst().removeDuplicates()) { state in
            store.invalidate()
            if state == .connected { Task { await store.load() } }
        }
        .onDisappear { store.invalidate() }
        .confirmationDialog("Test provider on this host?", isPresented: testConfirmation, presenting: providerToTest) { provider in
            Button("Test \(provider.name)") {
                guard canEdit else { return }
                Task { await store.testProvider(provider.id) }
            }
        } message: { _ in
            Text("This sends a short prompt using the host’s provider account and may incur provider charges.")
        }
        .accessibilityIdentifier("settings.providers")
    }

    private var hostSection: some View {
        SettingsSection(title: "CONNECTED HOST") {
            VStack(alignment: .leading, spacing: SettingsStyle.metadataSpacing) {
                Text(hostName).interFont(Constants.Typography.bodySEmphasized)
                Text("Provider changes apply to this host. To sign in or sign out, use Intent or the provider’s CLI on the host computer, then refresh here.")
                    .interFont(Constants.Typography.bodyS)
                    .foregroundStyle(SettingsStyle.muted(for: colorScheme, contrast: contrast))
                if !canEdit {
                    Text("Only the host owner can change or test providers.")
                        .interFont(Constants.Typography.bodyS)
                        .accessibilityIdentifier("settings.providers.readOnly")
                }
            }
        }
    }

    private func providerCard(_ provider: ProviderManagementStore.Provider) -> some View {
        VStack(alignment: .leading, spacing: SettingsStyle.metadataSpacing) {
            HStack(spacing: SettingsStyle.metadataSpacing) {
                providerIcon(provider.id)
                    .frame(width: SettingsStyle.iconWidth, height: SettingsStyle.iconWidth)
                    .accessibilityHidden(true)
                Text(provider.name).interFont(Constants.Typography.bodySEmphasized)
                Spacer(minLength: 0)
            }
            Text(authenticationLabel(provider.authentication))
                .interFont(Constants.Typography.bodyS)
                .foregroundStyle(SettingsStyle.muted(for: colorScheme, contrast: contrast))
                .accessibilityIdentifier("settings.providers.\(provider.id).status")
            providerToggle(provider)
            if !provider.canBeDisabled {
                Text("This provider is always enabled on the host.").interFont(Constants.Typography.subtextXXS)
            }
            if provider.supportsTestPrompt {
                Button("Test provider") { providerToTest = provider }
                    .disabled(!canEdit || !store.canManage || !provider.enabled)
                    .accessibilityIdentifier("settings.providers.\(provider.id).test")
            }
            if let message = store.testMessages[provider.id] {
                Text(message).interFont(Constants.Typography.bodyS)
                    .accessibilityIdentifier("settings.providers.\(provider.id).testResult")
            }
            if let url = provider.loginDocsURL {
                Link("Sign-in instructions", destination: url)
                    .accessibilityIdentifier("settings.providers.\(provider.id).instructions")
            }
        }
        .padding(SettingsStyle.contentMargin)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(SettingsStyle.card(for: colorScheme), in: .rect(cornerRadius: SettingsStyle.cardRadius))
    }

    private func providerToggle(_ provider: ProviderManagementStore.Provider) -> some View {
        Toggle("Enabled on this host", isOn: Binding(
            get: { provider.enabled },
            set: { enabled in
                guard canEdit else { return }
                Task { await store.setEnabled(enabled, providerID: provider.id) }
            }
        ))
        .interFont(Constants.Typography.bodyS)
        .disabled(!canEdit || !provider.canBeDisabled || !store.canManage)
        .accessibilityIdentifier("settings.providers.\(provider.id).enabled")
    }

    @ViewBuilder private func providerIcon(_ id: String) -> some View {
        switch id {
        case "codex": Image(.openAI).resizable().scaledToFit().accessibilityHidden(true)
        case "antigravity": Image(.gemini).resizable().scaledToFit().accessibilityHidden(true)
        default: Image(.agents).resizable().scaledToFit().accessibilityHidden(true)
        }
    }

    private func authenticationLabel(_ authentication: ProviderAuthentication) -> String {
        switch authentication {
        case .signedIn: "Signed in on host"
        case .signedOut: "Not signed in on host"
        case .unknown: "Sign-in status unknown"
        }
    }

    private var testConfirmation: Binding<Bool> {
        Binding(get: { providerToTest != nil }, set: { if !$0 { providerToTest = nil } })
    }

    private var canEdit: Bool { session.connection.currentPrincipal?.isOwner == true }
}
