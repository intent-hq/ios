import SwiftUI

struct DisconnectedView: View {
    @Environment(AppCoordinator.self) var coordinator
    @Environment(BackendSession.self) var session
    @Environment(\.colorScheme) var colorScheme

    private var attemptNumber: Int {
        if case .reconnecting(let attempt) = session.connection.connectionState {
            return attempt
        }
        return 0
    }

    var body: some View {
        ZStack {
            Theme.background(for: colorScheme).ignoresSafeArea()
            disconnectedContent
        }
    }

    private var disconnectedContent: some View {
        VStack(spacing: Constants.Disconnected.contentSpacing) {
            Spacer()
            reconnectingIndicator
            Text("Connection Lost")
                .interFont(Constants.Typography.heading2.withFace(.bold))
                .foregroundStyle(Theme.foreground(for: colorScheme))
            connectionDescription
            attemptDescription
            certificateMismatches
            Spacer()
            homeButton
        }
    }

    private var reconnectingIndicator: some View {
        Circle()
            .fill(Color.orange)
            .frame(
                width: Constants.Disconnected.indicatorSize,
                height: Constants.Disconnected.indicatorSize
            )
            .scaleEffect(attemptNumber > 0 ? Constants.Disconnected.activeIndicatorScale : 1.0)
            .opacity(attemptNumber > 0 ? Constants.Disconnected.activeIndicatorOpacity : 1.0)
            .animation(
                .easeInOut(duration: Constants.Disconnected.indicatorAnimationDuration)
                    .repeatForever(autoreverses: true),
                value: attemptNumber
            )
    }

    @ViewBuilder
    private var connectionDescription: some View {
        if let connection = coordinator.windowConnection {
            Text("Reconnecting to \(connection.server.name)...")
                .interFont(Constants.Typography.bodyXS)
                .foregroundStyle(Theme.mutedForeground(for: colorScheme))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, Constants.Disconnected.horizontalPadding)
        }
    }

    @ViewBuilder
    private var attemptDescription: some View {
        if attemptNumber > 1 {
            Text("Attempt \(attemptNumber)")
                .interFont(Constants.Typography.subtextXXS)
                .foregroundStyle(Theme.mutedForeground(for: colorScheme))
        }
    }

    @ViewBuilder
    private var certificateMismatches: some View {
        if !session.connection.certMismatches.isEmpty {
            CertMismatchListView(mismatches: session.connection.certMismatches)
                .padding(.horizontal, Constants.Disconnected.horizontalPadding)
        }
    }

    private var homeButton: some View {
        Button(action: coordinator.onReturnToSavedMachines) {
            Text("Back to Home")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(IntentButtonStyle())
        .accessibilityHint("Return to your saved machines without forgetting this connection.")
        .accessibilityIdentifier("disconnected.home")
        .padding(.horizontal, Constants.Disconnected.horizontalPadding)
        .padding(.bottom, Constants.Disconnected.bottomPadding)
    }
}
