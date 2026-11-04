#if DEBUG
import Foundation
import Network

/// File-gated UI fixture only; never changes host/device networking or a socket.
final class DemoNetworkPathMonitor: NetworkPathMonitoring {
    private let directory: URL
    private var task: Task<Void, Never>?

    init(directory: URL) {
        self.directory = directory
    }

    isolated deinit { task?.cancel() }

    func start(onUpdate: @escaping @MainActor @Sendable (NetworkPathSnapshot) -> Void) {
        let directory = directory
        task = Task {
            if ProcessInfo.processInfo.arguments.contains("--demo-network-requires-connection") {
                onUpdate(NetworkPathSnapshot(status: .requiresConnection, interfaces: []))
            }
            do {
                try await DemoFixtures.wait(for: .triggerFile(directory.appendingPathComponent("network-offline")))
                try Task.checkCancellation()
                let reason: NWPath.UnsatisfiedReason = ProcessInfo.processInfo.arguments
                    .contains("--demo-network-local-denied") ? .localNetworkDenied : .notAvailable
                onUpdate(NetworkPathSnapshot(status: .unsatisfied, interfaces: [], unsatisfiedReason: reason))
                try await DemoFixtures.wait(for: .triggerFile(directory.appendingPathComponent("network-restored")))
                try Task.checkCancellation()
                onUpdate(NetworkPathSnapshot(status: .satisfied, interfaces: [("demo-radio", .cellular)]))
            } catch {
                // Scene background/teardown retires this monitor and any pending report.
            }
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
    }
}
#endif
