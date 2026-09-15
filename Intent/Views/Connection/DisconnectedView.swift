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
                .font(.title2.bold())
                .foregroundStyle(Theme.foreground(for: colorScheme))
            connectionDescription
            attemptDescription
            certificateMismatches
            Spacer()
            logOffButton
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
                .font(.subheadline)
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
                .font(.caption)
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

    private var logOffButton: some View {
        Button(action: {
            session.connection.disconnect()
            coordinator.onLogOff()
        }, label: {
            Text("Log Off")
                .font(.body.weight(.medium))
                .foregroundStyle(.red)
                .frame(maxWidth: .infinity)
                .padding(.vertical, Constants.Disconnected.buttonVerticalPadding)
                .background(Color.red.opacity(Constants.Disconnected.buttonBackgroundOpacity))
                .clipShape(RoundedRectangle(cornerRadius: Constants.Disconnected.buttonCornerRadius))
        })
        .padding(.horizontal, Constants.Disconnected.horizontalPadding)
        .padding(.bottom, Constants.Disconnected.bottomPadding)
    }
}
