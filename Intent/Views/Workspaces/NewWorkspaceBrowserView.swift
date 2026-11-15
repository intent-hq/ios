import SwiftUI

struct NewWorkspaceBrowserView: View {
    let workspaceId: String
    let store: WorkspaceBrowserStore
    let onCreate: (WorkspaceBrowser) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(BackendSession.self) private var session: BackendSession?
    @State private var address = ""
    @State private var errorMessage: String?
    @FocusState private var addressFocused: Bool

    var body: some View {
        NavigationStack {
            browserForm
            .navigationTitle("New browser")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    IntentIconButton(icon: .close, label: "Cancel") { dismiss() }
                }
                .intentToolbarSurface()
                ToolbarItem(placement: .confirmationAction) {
                    Button("Open", action: create)
                        .buttonStyle(IntentButtonStyle())
                        .fixedSize(horizontal: true, vertical: false)
                        .disabled(address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                .intentToolbarSurface()
            }
            .onAppear { addressFocused = true }
            .task(id: workspaceId) { await session?.agentBrowserHost.refreshPin(workspaceId: workspaceId) }
        }
    }

    private var browserForm: some View {
        Form {
            Section {
                TextField("localhost:3000", text: $address)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.go)
                    .focused($addressFocused)
                    .onSubmit(create)
                    .accessibilityLabel("Browser address")
            } header: {
                Text("Address").interFont(Constants.Typography.bodyXS)
            } footer: {
                Text("Use localhost and the server port to open a server running on your connected machine.")
                    .interFont(Constants.Typography.bodyXS)
            }
            if let host = session?.agentBrowserHost, host.isAvailable {
                Section {
                    Toggle(isOn: pinBinding(host)) {
                        Text("Agents browse on this device").interFont(Constants.Typography.bodyM)
                    }
                    .accessibilityIdentifier("browser.agentHost.toggle")
                } footer: {
                    Text("Agents in this workspace open their browser tabs here instead of on your computer. They pause while Intent is closed.")
                        .interFont(Constants.Typography.bodyXS)
                }
            }
            if let errorMessage {
                Text(errorMessage).interFont(Constants.Typography.bodyS).foregroundStyle(.red)
            }
        }
    }

    private func pinBinding(_ host: AgentBrowserHost) -> Binding<Bool> {
        Binding(
            get: { host.pinnedWorkspaces.contains(workspaceId) },
            set: { pinned in
                Task {
                    do { try await host.setPinned(pinned, workspaceId: workspaceId) } catch {
                        errorMessage = error.localizedDescription
                    }
                }
            }
        )
    }

    private func create() {
        do {
            let browser = try store.create(workspaceId: workspaceId, url: address)
            dismiss()
            onCreate(browser)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
