import SwiftUI

struct MobileTerminalView: View {
    let terminal: MobileTerminal
    let workspaceName: String
    let store: MobileTerminalStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var connection: MobileTerminalConnection
    @State private var controls = MobileTerminalControls()
    @State private var confirmClose = false
    @State private var isClosing = false

    init(terminal: MobileTerminal, workspaceName: String, store: MobileTerminalStore) {
        self.terminal = terminal
        self.workspaceName = workspaceName
        self.store = store
        _connection = State(initialValue: MobileTerminalConnection(store: store, terminal: terminal))
    }

    private var attachmentKey: String {
        "\(store.connectionGeneration)-\(scenePhase == .active)"
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            connectionStatus
            TerminalEmulatorView(connection: connection, controls: controls)
                .padding(.horizontal, TerminalAppearance.terminalInset)
                .disabled(!connection.isReady || !store.isActive(terminal))
                .task(id: attachmentKey) {
                    if scenePhase == .active { await connection.attach() } else { connection.detach() }
                }
                .onDisappear { connection.detach() }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            TerminalKeyBar(controls: controls, isEnabled: connection.isReady && store.isActive(terminal))
        }
        .background(TerminalAppearance.background.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .tint(.white)
        .interactiveDismissDisabled(isClosing)
        .alert("Close terminal?", isPresented: $confirmClose) { closeActions } message: {
            Text("This stops the shell and any commands running in it. Go back to leave it running.")
        }
        .onChange(of: store.isActive(terminal)) { _, active in
            if !active { connection.detach() }
        }
    }

    private var header: some View {
        HStack(spacing: TerminalAppearance.headerSpacing) {
            Button { dismiss() } label: {
                Image(systemName: "chevron.left")
                    .font(.title3.weight(.semibold))
                    .frame(width: TerminalAppearance.controlSize, height: TerminalAppearance.controlSize)
            }
            .buttonStyle(TerminalControlStyle())
            .modifier(TerminalControlSurface())
            .accessibilityLabel("Back to workspace")
            .accessibilityHint("Leaves the terminal running")
            .disabled(isClosing)
            title
            terminalMenu
        }
        .padding(.horizontal, TerminalAppearance.horizontalInset)
        .padding(.top, TerminalAppearance.headerSpacing)
        .padding(.bottom, TerminalAppearance.headerBottomInset)
    }

    private var title: some View {
        VStack(spacing: TerminalAppearance.groupInset) {
            Text(terminal.name)
                .interFont(Constants.Typography.bodyM.withFace(.semibold))
                .foregroundStyle(.white)
                .accessibilityIdentifier("mobile-terminal-title")
            Text(workspaceName)
                .interFont(Constants.Typography.bodyXS)
                .foregroundStyle(TerminalAppearance.muted)
        }
        .lineLimit(1)
        .frame(maxWidth: .infinity)
    }

    private var terminalMenu: some View {
        Menu {
            Button {
                Task { await connection.attach() }
            } label: {
                Label {
                    Text("Reconnect").interFont(Constants.Typography.bodyS)
                } icon: {
                    Image(systemName: "arrow.clockwise")
                }
            }
            .disabled(!store.isConnected || !store.isActive(terminal))
            Button(role: .destructive) {
                confirmClose = true
            } label: {
                Label {
                    Text("Close terminal").interFont(Constants.Typography.bodyS)
                } icon: {
                    Image(systemName: "xmark.circle")
                }
            }
            .disabled(!store.isConnected || isClosing)
        } label: {
            Image(systemName: "ellipsis")
                .font(.title3.weight(.semibold))
                .frame(width: TerminalAppearance.controlSize, height: TerminalAppearance.controlSize)
        }
        .buttonStyle(TerminalControlStyle())
        .modifier(TerminalControlSurface())
        .accessibilityLabel("Terminal actions")
    }

    @ViewBuilder
    private var closeActions: some View {
        Button("Cancel", role: .cancel) {}
        Button("Close terminal", role: .destructive) {
            isClosing = true
            Task {
                if await store.close(terminal) { dismiss() }
                isClosing = false
            }
        }
    }

    @ViewBuilder
    private var connectionStatus: some View {
        if !store.isActive(terminal) {
            status("Session ended. Use New terminal to start another.")
        } else if !store.isConnected {
            status("Disconnected. Your terminal stays on the server.")
        } else if let error = connection.errorMessage ?? store.errorMessage(workspaceId: terminal.workspaceId) {
            status(error)
        } else if !connection.isReady {
            ProgressView {
                Text("Connecting to terminal…").interFont(Constants.Typography.bodyS)
            }
            .tint(TerminalAppearance.green)
            .padding()
        }
    }

    private func status(_ message: String) -> some View {
        Text(message)
            .interFont(Constants.Typography.bodyS)
            .foregroundStyle(TerminalAppearance.muted)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, TerminalAppearance.horizontalInset)
            .padding(.bottom, TerminalAppearance.headerSpacing)
            .accessibilityAddTraits(.updatesFrequently)
    }
}
