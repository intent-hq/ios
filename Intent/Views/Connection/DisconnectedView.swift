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

            VStack(spacing: Constants.Disconnected.contentSpacing) {
                Spacer()

                // Pulsing dot animation
                Circle()
                    .fill(Color.orange)
                    .frame(width: Constants.Disconnected.indicatorSize,
                           height: Constants.Disconnected.indicatorSize)
                    .scaleEffect(attemptNumber > 0 ? Constants.Disconnected.activeIndicatorScale : 1.0)
                    .opacity(attemptNumber > 0 ? Constants.Disconnected.activeIndicatorOpacity : 1.0)
                    .animation(
                        .easeInOut(duration: Constants.Disconnected.indicatorAnimationDuration)
                            .repeatForever(autoreverses: true),
                        value: attemptNumber)

                Text("Connection Lost")
                    .font(.title2.bold())
                    .foregroundStyle(Theme.foreground(for: colorScheme))

                if let pairing = PersistenceManager.shared.loadPairing() {
                    Text("Reconnecting to \(pairing.server.name)...")
                        .font(.subheadline)
                        .foregroundStyle(Theme.mutedForeground(for: colorScheme))
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, Constants.Disconnected.horizontalPadding)
                }

                if attemptNumber > 1 {
                    Text("Attempt \(attemptNumber)")
                        .font(.caption)
                        .foregroundStyle(Theme.mutedForeground(for: colorScheme))
                }

                // Passive per-host cert-mismatch list, for parity with the
                // live reconnect surface (RootView's isDisconnected overlay).
                // Note: no coordinator path currently routes to the
                // .disconnected screen, so this renders only if that screen
                // gets wired up.
                if !session.connection.certMismatches.isEmpty {
                    CertMismatchListView(mismatches: session.connection.certMismatches)
                        .padding(.horizontal, 32)
                }

                Spacer()

                Button(action: {
                    session.connection.disconnect()
                    coordinator.onLogOff()
                }) {
                    Text("Log Off")
                        .font(.body.weight(.medium))
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, Constants.Disconnected.buttonVerticalPadding)
                        .background(Color.red.opacity(Constants.Disconnected.buttonBackgroundOpacity))
                        .clipShape(RoundedRectangle(cornerRadius: Constants.Disconnected.buttonCornerRadius))
                }
                .padding(.horizontal, Constants.Disconnected.horizontalPadding)
                .padding(.bottom, Constants.Disconnected.bottomPadding)
            }
        }
    }
}

