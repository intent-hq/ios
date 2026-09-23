import Foundation
import Network

nonisolated struct NetworkPathSnapshot: Equatable, Sendable {
    let status: NWPath.Status
    /// Meaningful only for an unsatisfied path; not a diagnosis of Airplane Mode.
    let unsatisfiedReason: NWPath.UnsatisfiedReason?
    let primaryInterface: String?
    let availableInterfaces: [String]
    /// Physical members in NWPath's preference order, even under a virtual primary.
    let physicalInterfaces: [String]

    /// Preserve the transport's existing satisfied/not-satisfied interpretation.
    var isSatisfied: Bool { status == .satisfied }

    var isOnPhysicalInterface: Bool {
        primaryInterface.map { physicalInterfaces.contains($0) } ?? false
    }

    init(
        isSatisfied: Bool,
        interfaces: [(name: String, type: NWInterface.InterfaceType)]
    ) {
        self.init(status: isSatisfied ? .satisfied : .unsatisfied, interfaces: interfaces)
    }

    init(
        status: NWPath.Status,
        interfaces: [(name: String, type: NWInterface.InterfaceType)],
        unsatisfiedReason: NWPath.UnsatisfiedReason? = nil
    ) {
        self.status = status
        self.unsatisfiedReason = status == .unsatisfied ? unsatisfiedReason : nil
        primaryInterface = interfaces.first?.name
        availableInterfaces = interfaces.map(\.name)
        physicalInterfaces = interfaces.compactMap { interface in
            switch interface.type {
            case .wifi, .cellular, .wiredEthernet:
                interface.name
            case .loopback, .other:
                nil
            @unknown default:
                nil
            }
        }
    }

    init(_ path: NWPath) {
        self.init(
            status: path.status,
            interfaces: path.availableInterfaces.map { (name: $0.name, type: $0.type) },
            unsatisfiedReason: path.status == .unsatisfied ? path.unsatisfiedReason : nil
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
