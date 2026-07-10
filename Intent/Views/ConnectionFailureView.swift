import SwiftUI

struct ConnectionFailureView: View {
    @EnvironmentObject var coordinator: AppCoordinator
    @Environment(\.colorScheme) var colorScheme
    let errorMessage: String
    var isCertMismatch: Bool = false
    @State private var isRetrying = false
    @State private var attemptNumber = 0
    @State private var retryTask: Task<Void, Never>?

    var body: some View {
        ZStack {
            Theme.background(for: colorScheme).ignoresSafeArea()

            VStack(spacing: 24) {
                Spacer()

                // Error icon
                ZStack {
                    Circle()
                        .fill(Theme.destructive(for: colorScheme).opacity(0.1))
                        .frame(width: 80, height: 80)
                    Image(systemName: "wifi.exclamationmark")
                        .font(.system(size: 32))
                        .foregroundStyle(Theme.destructive(for: colorScheme))
                }

                VStack(spacing: 8) {
                    Text("Can't Connect")
                        .font(.title2.bold())
                        .foregroundStyle(Theme.foreground(for: colorScheme))

                    Text(errorMessage)
                        .font(.subheadline)
                        .foregroundStyle(Theme.mutedForeground(for: colorScheme))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                }

                VStack(spacing: 12) {
                    // Auto-retry progress
                    if isRetrying {
                        HStack(spacing: 8) {
                            ProgressView()
                            if attemptNumber > 1 {
                                Text("Attempt \(attemptNumber)")
                                    .font(.caption)
                                    .foregroundStyle(Theme.mutedForeground(for: colorScheme))
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(Theme.muted(for: colorScheme).opacity(0.3))
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                    }

                    // Re-pair button
                    Button {
                        retryTask?.cancel()
                        coordinator.onReconnect()
                    } label: {
                        Label(isCertMismatch ? "Re-pair Device" : "Connect to Different Server",
                              systemImage: isCertMismatch ? "arrow.triangle.2.circlepath" : "link.badge.plus")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .tint(Theme.primary(for: colorScheme))
                }
                .padding(.horizontal, 24)

                Spacer()

                // Help text
                VStack(spacing: 4) {
                    Text("Troubleshooting")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Theme.foreground(for: colorScheme))
                    Text("• Make sure Intent is running on your Mac\n• Check that both devices are on the same network\n• Verify the WebSocket API is enabled in Settings")
                        .font(.caption)
                        .foregroundStyle(Theme.mutedForeground(for: colorScheme))
                        .multilineTextAlignment(.leading)
                }
                .padding(.horizontal, 32)
                .padding(.bottom, 32)
            }
        }
        .onAppear {
            if !isCertMismatch {
                startAutoRetry()
            }
        }
        .onDisappear {
            retryTask?.cancel()
        }
    }

    private func startAutoRetry() {
        retryTask?.cancel()
        retryTask = Task {
            var attempt = 0
            while !Task.isCancelled {
                attempt += 1
                await MainActor.run {
                    attemptNumber = attempt
                    isRetrying = true
                }

                // Exponential backoff: 2s, 4s, 8s, 16s, max 30s
                let delay = min(Double(1 << min(attempt, 5)), 30.0)
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                if Task.isCancelled { break }

                // Try to connect
                guard let pairing = PersistenceManager.shared.loadPairing() else {
                    await MainActor.run { coordinator.currentScreen = .pairing }
                    return
                }

                do {
                    try await ConnectionManager.shared.connect(
                        hosts: pairing.server.hosts,
                        port: pairing.server.port,
                        token: pairing.token,
                        certFingerprint: pairing.server.certFingerprint
                    )
                    await MainActor.run { coordinator.onConnectionSuccess() }
                    return
                } catch {
                    // Continue retrying
                    print("[ConnectionFailureView] Retry \(attempt) failed: \(error)")
                }
            }
        }
    }
}

#Preview("Connection Failed") {
    ConnectionFailureView(errorMessage: "The server at 192.168.1.42:5179 is not responding.")
        .environmentObject(AppCoordinator())
}

#Preview("Connection Failed - Dark") {
    ConnectionFailureView(errorMessage: "Connection timed out after 10 seconds.")
        .environmentObject(AppCoordinator())
        .preferredColorScheme(.dark)
}

