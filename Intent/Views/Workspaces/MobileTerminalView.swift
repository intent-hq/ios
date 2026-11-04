import SwiftUI

struct MobileTerminalView: View {
    let terminal: MobileTerminal
    let workspaceName: String
    let store: MobileTerminalStore
    var onClose: (() -> Void)?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.isIPadPaneVisible) private var isPaneVisible
    @State private var connection: MobileTerminalConnection
    @State private var controls = MobileTerminalControls()
    @State private var confirmClose = false
    @State private var isClosing = false
    @State private var hasPresented = false

    init(terminal: MobileTerminal, workspaceName: String, store: MobileTerminalStore, onClose: (() -> Void)? = nil) {
        self.terminal = terminal
        self.workspaceName = workspaceName
        self.store = store
        self.onClose = onClose
        _connection = State(initialValue: MobileTerminalConnection(store: store, terminal: terminal))
    }

    private var attachmentKey: String {
        "\(store.connectionGeneration)-\(canAttach)"
    }

    private var canAttach: Bool { isPaneVisible && scenePhase == .active && store.isActive(terminal) }
    private var canInteract: Bool { canAttach && connection.isReady }

    var body: some View {
        VStack(spacing: 0) {
            header
            connectionStatus
            terminalContent
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            TerminalKeyBar(controls: controls, isEnabled: canInteract)
        }
        .background(TerminalAppearance.background.ignoresSafeArea())
        .background(TerminalPresentationObserver { hasPresented = true })
        .preferredColorScheme(onClose == nil ? .dark : nil)
        .environment(\.colorScheme, .dark)
        .tint(.white)
        .interactiveDismissDisabled(isClosing)
        .alert("Close terminal?", isPresented: $confirmClose) { closeActions } message: {
            Text("This stops the shell and any commands running in it. Go back to leave it running.")
        }
        .onChange(of: canAttach) { _, active in
            if !active {
                controls.terminalView?.resignFirstResponder()
                connection.detach()
            }
        }
    }

    private var terminalContent: some View {
        ZStack(alignment: .top) {
            if hasPresented {
                TerminalEmulatorView(connection: connection, controls: controls)
                    .disabled(!canInteract)
                    .task(id: attachmentKey) {
                        if canAttach { await connection.attach() } else { connection.detach() }
                    }
                    .onDisappear { connection.detach() }
            } else {
                Color.clear
            }
            if !connection.isReady, store.isConnected, store.isActive(terminal),
               connection.errorMessage == nil, store.errorMessage(workspaceId: terminal.workspaceId) == nil {
                ProgressView {
                    Text("Connecting to terminal…").interFont(Constants.Typography.bodyS)
                }
                .tint(TerminalAppearance.green)
                .padding()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, TerminalAppearance.terminalInset)
    }

    @ViewBuilder
    private var header: some View {
        if onClose != nil {
            WorkspaceNavigationHeader(
                title: terminal.name,
                subtitle: "\(workspaceName)",
                backLabel: "Back to workspace",
                backIdentifier: "terminal.main.close",
                titleIdentifier: "mobile-terminal-title",
                isLeadingActionEnabled: !isClosing,
                showsBackground: false,
                usesConversationLayout: true,
                onBack: leaveTerminal
            ) {
                terminalMenu
            }
        } else {
            standaloneHeader
        }
    }

    private var standaloneHeader: some View {
        HStack(spacing: TerminalAppearance.headerSpacing) {
            Button(action: leaveTerminal) {
                Image(.arrowLeft)
                    .resizable()
                    .scaledToFit()
                    .frame(width: WorkspaceDetailStyle.iconSize, height: WorkspaceDetailStyle.iconSize)
                    .frame(width: TerminalAppearance.controlSize, height: TerminalAppearance.controlSize)
            }
            .buttonStyle(TerminalControlStyle())
            .modifier(TerminalControlSurface())
            .accessibilityLabel("Back to workspace")
            .accessibilityHint("Leaves the terminal running")
            .disabled(isClosing)
            title
            terminalMenu
                .buttonStyle(TerminalControlStyle())
                .modifier(TerminalControlSurface())
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
                Task { if canAttach { await connection.attach() } }
            } label: {
                Label {
                    Text("Reconnect").interFont(Constants.Typography.bodyS)
                } icon: {
                    Image(.clockwiseArrow)
                }
            }
            .disabled(!hasPresented || !store.isConnected || !canAttach)
            Button(role: .destructive) {
                confirmClose = true
            } label: {
                Label {
                    Text("Close terminal").interFont(Constants.Typography.bodyS)
                } icon: {
                    Image(.closeCircle)
                }
            }
            .disabled(!store.isConnected || isClosing)
        } label: {
            Image(.more)
                .resizable()
                .scaledToFit()
                .frame(width: WorkspaceDetailStyle.iconSize, height: WorkspaceDetailStyle.iconSize)
                .frame(width: headerControlSize, height: headerControlSize)
                .accessibilityHidden(true)
        }
        .accessibilityLabel("Terminal actions")
    }

    private var headerControlSize: CGFloat {
        onClose == nil ? TerminalAppearance.controlSize : Constants.Conversation.Design.Header.controlSize
    }

    @ViewBuilder
    private var closeActions: some View {
        Button("Cancel", role: .cancel) {}
        Button("Close terminal", role: .destructive) {
            isClosing = true
            Task {
                if await store.close(terminal) { leaveTerminal() }
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

    private func leaveTerminal() {
        if let onClose { onClose() } else { dismiss() }
    }
}
