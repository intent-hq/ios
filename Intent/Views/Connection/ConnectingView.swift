import SwiftUI

struct ConnectingView: View {
    @Environment(AppCoordinator.self) var coordinator
    @Environment(BackendSession.self) var session
    @Environment(\.colorScheme) private var colorScheme
    var networkStatus: NetworkAvailability.Status = .unknown

    private typealias Layout = Constants.Connecting

    private var statusColorScheme: ColorScheme {
        coordinator.connectingStartedByLaunch ? .light : colorScheme
    }

    var body: some View {
        VStack {
            Spacer()
            if let startup = session.connection.startupState {
                ScrollView {
                    DaemonStartupProgressView(state: startup, onRetry: coordinator.restartConnectionAttempt)
                        .padding()
                        .frame(maxWidth: .infinity)
                }
                .scrollBounceBehavior(.basedOnSize)
            }
            #if DEBUG
            if DemoConnectionLoss.initialDataGate != nil {
                Text(verbatim: String(describing: session.connection.connectionState))
                    .accessibilityIdentifier("demo-connection-startup")
            }
            #endif
            if ConnectionNetworkMessage(status: networkStatus).isUnavailable {
                ConnectionNetworkStatusView(status: networkStatus)
                    .padding(.horizontal, Layout.mismatchHorizontalPadding)
            }
            if !session.connection.certMismatches.isEmpty {
                CertMismatchListView(
                    mismatches: session.connection.certMismatches,
                    warningForeground: Theme.foreground(for: statusColorScheme)
                )
                .padding(.horizontal, Layout.mismatchHorizontalPadding)
            }
        }
        .foregroundStyle(Theme.foreground(for: statusColorScheme))
        .environment(\.colorScheme, statusColorScheme)
        .padding(.bottom, Layout.contentBottomPadding)
        .frame(maxWidth: .infinity)
        .safeAreaInset(edge: .top, alignment: .leading, spacing: 0) {
            if !coordinator.connectingStartedByLaunch || session.connection.startupState != nil {
                ConnectionBackButton(action: coordinator.onReturnToSavedMachines)
                    .accessibilityIdentifier("connecting.home")
                    .padding(.horizontal, Constants.ConnectionSheet.inset)
            }
        }
        .task(id: coordinator.connectionAttemptId) {
            await attemptConnection()
        }
    }

    private func connectDemoSessionIfRequested() -> Bool {
        #if DEBUG
        guard DemoMode.pretendPaired, !DemoStartupConnection.isEnabled else { return false }
        session.connection.connectDemo(serveFixtures: DemoMode.isEnabled)
        return true
        #else
        false
        #endif
    }

    private func connectSavedMachine() async -> Bool {
        guard let connection = coordinator.windowConnection else {
            if coordinator.backendID != nil {
                coordinator.onConnectionFailed(
                    error: String(localized: "This connection is no longer saved.")
                )
            } else {
                coordinator.currentScreen = .pairing
            }
            return false
        }

        let attemptsBefore = session.connection.connectAttemptCount
        do {
            try await DiagnosticConnectContext.$origin.withValue(.saved) {
                try await session.connection.connect(
                    hosts: connection.server.hosts,
                    port: connection.server.port,
                    token: connection.token,
                    certFingerprint: connection.server.certFingerprint,
                    tcAddress: connection.server.tcAddress
                )
            }
        } catch {
            guard !Task.isCancelled else { return false }
            let replaced = session.connection.connectAttemptCount > attemptsBefore + 1
            switch Self.failureOutcome(for: error, replacedByNewerAttempt: replaced) {
            case .leave:
                break
            case .retry:
                if case .connecting = coordinator.currentScreen { coordinator.restartConnectionAttempt() }
            case .show(let message):
                coordinator.onConnectionFailed(error: message)
            }
            return false
        }
        if !PersistenceManager.shared.touchLastConnected(id: connection.id) {
            AppLog.connection.warning("[ConnectingView] Could not persist last-connected timestamp")
        }
        return true
    }

    enum FailureOutcome: Equatable {
        case leave
        case retry
        case show(String)
    }

    nonisolated static func failureOutcome(for error: any Error, replacedByNewerAttempt: Bool) -> FailureOutcome {
        if error is CancellationError { return replacedByNewerAttempt ? .leave : .retry }
        if case DaemonStartupError.failed = error { return .leave }
        return .show(error.localizedDescription)
    }

    private func attemptConnection() async {
        guard !coordinator.lifecycleState.hasReturnedToSavedMachines else { return }
        let attemptID = coordinator.connectionAttemptId
        if !connectDemoSessionIfRequested() {
            guard await connectSavedMachine() else { return }
        }

        do {
            #if DEBUG
            if let gate = DemoConnectionLoss.initialRoutingGate {
                try await DemoFixtures.wait(for: gate)
            }
            #endif
            try await waitForWorkspaceData(timeout: Constants.Connecting.workspaceLoadTimeout)
        } catch {
            return
        }
        coordinator.onInitialWorkspaceLoadComplete(attemptID: attemptID)
    }

    private func waitForWorkspaceData(timeout: Duration) async throws {
        try await LaunchPhaseTimeline.poll(
            until: { session.workspaceStore.lastUpdated != nil },
            timeout: timeout,
            interval: Constants.Connecting.workspacePollInterval
        )
    }
}
