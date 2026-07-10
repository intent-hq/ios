import SwiftUI

struct DisconnectedView: View {
    @EnvironmentObject var coordinator: AppCoordinator
    @EnvironmentObject var connectionManager: ConnectionManager
    @Environment(\.colorScheme) var colorScheme

    private var attemptNumber: Int {
        if case .reconnecting(let attempt) = connectionManager.connectionState {
            return attempt
        }
        return 0
    }

    var body: some View {
        ZStack {
            Theme.background(for: colorScheme).ignoresSafeArea()

            VStack(spacing: 24) {
                Spacer()

                // Pulsing dot animation
                Circle()
                    .fill(Color.orange)
                    .frame(width: 12, height: 12)
                    .scaleEffect(attemptNumber > 0 ? 1.5 : 1.0)
                    .opacity(attemptNumber > 0 ? 0.5 : 1.0)
                    .animation(.easeInOut(duration: 1.0).repeatForever(autoreverses: true), value: attemptNumber)

                Text("Connection Lost")
                    .font(.title2.bold())
                    .foregroundStyle(Theme.foreground(for: colorScheme))

                if let pairing = PersistenceManager.shared.loadPairing() {
                    Text("Reconnecting to \(pairing.server.name)...")
                        .font(.subheadline)
                        .foregroundStyle(Theme.mutedForeground(for: colorScheme))
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 32)
                }

                if attemptNumber > 1 {
                    Text("Attempt \(attemptNumber)")
                        .font(.caption)
                        .foregroundStyle(Theme.mutedForeground(for: colorScheme))
                }

                Spacer()

                Button(action: {
                    connectionManager.disconnect()
                    coordinator.onLogOff()
                }) {
                    Text("Log Off")
                        .font(.body.weight(.medium))
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(Color.red.opacity(0.1))
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                .padding(.horizontal, 32)
                .padding(.bottom, 32)
            }
        }
    }
}

