import SwiftUI

struct MobileTerminalView: View {
    let terminal: MobileTerminal
    let store: MobileTerminalStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var connection: MobileTerminalConnection
    @State private var confirmClose = false
    @State private var isClosing = false

    init(terminal: MobileTerminal, store: MobileTerminalStore) {
        self.terminal = terminal
        self.store = store
        _connection = State(initialValue: MobileTerminalConnection(store: store, terminal: terminal))
    }

    private var attachmentKey: String {
        "\(store.connectionGeneration)-\(scenePhase == .active)"
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                connectionStatus
                TerminalEmulatorView(connection: connection)
                    .disabled(!connection.isReady || !store.isActive(terminal))
                    .task(id: attachmentKey) {
                        if scenePhase == .active { await connection.attach() } else { connection.detach() }
                    }
                    .onDisappear { connection.detach() }
            }
            .navigationTitle(terminal.name)
            .toolbarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button("Reconnect", systemImage: "arrow.clockwise") {
                            Task { await connection.attach() }
                        }
                        .disabled(!store.isConnected || !store.isActive(terminal))
                        Button("Close terminal", systemImage: "xmark.circle", role: .destructive) {
                            confirmClose = true
                        }
                        .disabled(!store.isConnected || isClosing)
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .accessibilityLabel("Terminal actions")
                }
            }
            .alert("Close terminal?", isPresented: $confirmClose) {
                Button("Cancel", role: .cancel) {}
                Button("Close terminal", role: .destructive) {
                    isClosing = true
                    Task {
                        if await store.close(terminal) { dismiss() }
                        isClosing = false
                    }
                }
            } message: {
                Text("This stops the shell and any commands running in it. Use Done to leave it running.")
            }
            .onChange(of: store.isActive(terminal)) { _, active in
                if !active { connection.detach() }
            }
        }
        .interactiveDismissDisabled(isClosing)
    }

    @ViewBuilder
    private var connectionStatus: some View {
        if !store.isActive(terminal) {
            status("Session ended. Use New terminal to start another.")
        } else if !store.isConnected {
            status("Disconnected. Your terminal stays on the server.")
        } else if let error = connection.errorMessage ?? store.errorMessage {
            status(error)
        } else if !connection.isReady {
            ProgressView("Connecting to terminal…")
                .padding()
        }
    }

    private func status(_ message: String) -> some View {
        Text(message)
            .font(.callout)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
            .background(.bar)
            .accessibilityAddTraits(.updatesFrequently)
    }
}
