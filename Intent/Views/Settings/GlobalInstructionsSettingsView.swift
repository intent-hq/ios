import SwiftUI

struct GlobalInstructionsSettingsView: View {
    @Environment(BackendSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @State private var store: GlobalInstructionsStore
    @State private var showingDiscardConfirmation = false
    private let hostName: String

    init(connection: ConnectionManagerRouting, hostName: String) {
        self.hostName = hostName
        _store = State(initialValue: GlobalInstructionsStore(connection: connection))
    }

    var body: some View {
        NavigationStack {
            content
            .padding(SettingsStyle.contentMargin)
            .frame(maxWidth: SettingsStyle.maximumContentWidth)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(SettingsStyle.surface(for: colorScheme))
            .foregroundStyle(SettingsStyle.foreground(for: colorScheme))
            .navigationTitle("Global instructions")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") {
                        if store.hasChanges { showingDiscardConfirmation = true } else { dismiss() }
                    }
                    .disabled(store.isSaving)
                    .accessibilityIdentifier("settings.instructions.close")
                }
                ToolbarItem(placement: .confirmationAction) {
                    if canEdit {
                        Button(store.isSaving ? "Saving…" : "Save") { Task { await store.save() } }
                            .disabled(!store.hasChanges || store.isSaving)
                            .accessibilityIdentifier("settings.instructions.save")
                    }
                }
            }
            .toolbar(.visible, for: .navigationBar)
            .confirmationDialog("Discard your changes?", isPresented: $showingDiscardConfirmation, titleVisibility: .visible) {
                Button("Discard changes", role: .destructive) { dismiss() }
                Button("Keep editing", role: .cancel) {}
            }
        }
        .interactiveDismissDisabled(store.hasChanges || store.isSaving)
        .task { await store.load() }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: SettingsStyle.sectionSpacing) {
            Text("Applies to all agents on \(hostName).")
                .interFont(Constants.Typography.bodyS)
                .foregroundStyle(.secondary)
            if store.isLoaded {
                editor
            } else if store.errorMessage == nil {
                ProgressView("Loading instructions…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            if let message = store.errorMessage {
                errorMessage(message)
            }
            if !store.isLoaded { Spacer(minLength: 0) }
        }
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: SettingsStyle.sectionSpacing) {
            if !canEdit {
                Text("Only the host owner can edit these instructions.")
                    .interFont(Constants.Typography.bodyS)
                    .foregroundStyle(.secondary)
            }
            Toggle("Use custom instructions", isOn: $store.enabled)
                .interFont(Constants.Typography.bodySEmphasized)
                .padding(SettingsStyle.rowVerticalPadding)
                .background(SettingsStyle.card(for: colorScheme), in: .rect(cornerRadius: SettingsStyle.cardRadius))
                .accessibilityIdentifier("settings.instructions.enabled")
            TextEditor(text: $store.content)
                .interFont(Constants.Typography.bodyS)
                .scrollContentBackground(.hidden)
                .padding(SettingsStyle.rowVerticalPadding)
                .background(SettingsStyle.card(for: colorScheme), in: .rect(cornerRadius: SettingsStyle.cardRadius))
                .accessibilityLabel("Custom instructions")
                .accessibilityIdentifier("settings.instructions.content")
        }
        .disabled(store.isSaving || !canEdit)
    }

    private var canEdit: Bool { session.connection.currentPrincipal?.isOwner == true }

    private func errorMessage(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: SettingsStyle.metadataSpacing) {
            Text(message)
                .interFont(Constants.Typography.bodyS)
                .accessibilityIdentifier("settings.instructions.error")
            if !store.isLoaded {
                Button("Retry") { Task { await store.load() } }
            }
        }
    }
}
