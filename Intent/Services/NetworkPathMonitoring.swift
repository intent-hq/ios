import Foundation
import Network

nonisolated struct NetworkPathSnapshot: Equatable, Sendable {
    let isSatisfied: Bool
    let primaryInterface: String?
    let availableInterfaces: [String]
    let isOnPhysicalInterface: Bool

    init(
        isSatisfied: Bool,
        primaryInterface: String?,
        availableInterfaces: [String],
        isOnPhysicalInterface: Bool
    ) {
        self.isSatisfied = isSatisfied
        self.primaryInterface = primaryInterface
        self.availableInterfaces = availableInterfaces
        self.isOnPhysicalInterface = isOnPhysicalInterface
    }

    init(isSatisfied: Bool, primaryInterface: String?) {
        self.init(
            isSatisfied: isSatisfied,
            primaryInterface: primaryInterface,
            availableInterfaces: [primaryInterface].compactMap { $0 },
            isOnPhysicalInterface: primaryInterface != nil
        )
    }

    init(isSatisfied: Bool, primaryInterface: String?, availableInterfaces: [String]) {
        self.init(
            isSatisfied: isSatisfied,
            primaryInterface: primaryInterface,
            availableInterfaces: availableInterfaces,
            isOnPhysicalInterface: primaryInterface != nil
        )
    }

    init(isSatisfied: Bool, primaryInterface: String?, isOnPhysicalInterface: Bool) {
        self.init(
            isSatisfied: isSatisfied,
            primaryInterface: primaryInterface,
            availableInterfaces: [primaryInterface].compactMap { $0 },
            isOnPhysicalInterface: isOnPhysicalInterface
        )
    }

    init(_ path: NWPath) {
        let interfaces = path.availableInterfaces
        let isPhysical: Bool
        switch interfaces.first?.type {
        case .wifi, .cellular, .wiredEthernet:
            isPhysical = true
        case .loopback, .other, nil:
            isPhysical = false
        @unknown default:
            isPhysical = false
        }
        self.init(
            isSatisfied: path.status == .satisfied,
            primaryInterface: interfaces.first?.name,
            availableInterfaces: interfaces.map(\.name),
            isOnPhysicalInterface: isPhysical
        )
    }
}

protocol NetworkPathMonitoring: AnyObject {
    func start(onUpdate: @escaping @MainActor @Sendable (NetworkPathSnapshot) -> Void)
    func cancel()
}

final class NWPathMonitorAdapter: NetworkPathMonitoring {
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "ConnectionManager.pathMonitor")

    isolated deinit {
        monitor.cancel()
    }

    func start(onUpdate: @escaping @MainActor @Sendable (NetworkPathSnapshot) -> Void) {
        monitor.pathUpdateHandler = { @Sendable path in
            let snapshot = NetworkPathSnapshot(path)
            Task { @MainActor in onUpdate(snapshot) }
        }
        monitor.start(queue: queue)
    }

    func cancel() {
        monitor.cancel()
    }
}
