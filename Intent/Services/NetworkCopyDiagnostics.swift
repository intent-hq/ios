#if DEBUG
import Foundation
import Network
import Observation
import SwiftUI

/// Temporary, opt-in phone evidence. Never accepts free-form text or writes data.
@MainActor @Observable
final class NetworkCopyDiagnostics {
    static let launchArgument = "--diagnose-network-copy"
    static let maximumEntries = 12
    static let current = make(arguments: ProcessInfo.processInfo.arguments)

    enum Phase: String {
        case active, background, inactive, stopped, unknown

        init(_ phase: ScenePhase) {
            switch phase {
            case .active: self = .active
            case .inactive: self = .inactive
            case .background: self = .background
            @unknown default: self = .unknown
            }
        }
    }

    enum Event: Equatable {
        case scene(Phase, lease: Bool)
        case monitor(NetworkAvailability.Status, accepted: Bool)
        case presenter(NetworkAvailability.Status, offline: Bool, presented: Bool)

        var line: String {
            switch self {
            case let .scene(phase, lease):
                return "scene=\(phase.rawValue) lease=\(lease)"
            case let .monitor(status, accepted):
                return "monitor \(Self.fields(status)) delivery=\(accepted ? "accepted" : "stale")"
            case let .presenter(status, offline, presented):
                return "presenter \(Self.fields(status)) "
                    + "copy=\(offline ? "offline" : "reconnecting") visible=\(presented)"
            }
        }

        private static func fields(_ status: NetworkAvailability.Status) -> String {
            switch status {
            case .unknown: return "status=unknown reason=none"
            case .requiresConnection: return "status=requiresConnection reason=none"
            case .satisfied: return "status=satisfied reason=none"
            case let .unsatisfied(reason): return "status=unsatisfied reason=\(reasonName(reason))"
            }
        }

        private static func reasonName(_ reason: NWPath.UnsatisfiedReason?) -> String {
            guard let reason else { return "none" }
            switch reason {
            case .notAvailable: return "notAvailable"
            case .cellularDenied: return "cellularDenied"
            case .wifiDenied: return "wifiDenied"
            case .localNetworkDenied: return "localNetworkDenied"
            case .vpnInactive: return "vpnInactive"
            @unknown default: return "other"
            }
        }
    }

    struct Entry: Equatable {
        let sequence: Int
        let event: Event
    }

    // Recording must not subscribe the presenter to subsequent diagnostic events.
    @ObservationIgnored private(set) var entries: [Entry] = []
    @ObservationIgnored private var sequence = 0
    private(set) var readout = ""

    private init() {}

    static func make(arguments: [String]) -> NetworkCopyDiagnostics? {
        guard arguments.contains(launchArgument) else { return nil }
        return NetworkCopyDiagnostics()
    }

    func record(_ event: Event) {
        guard entries.last?.event != event else { return }
        sequence += 1
        entries.append(Entry(sequence: sequence, event: event))
        if entries.count > Self.maximumEntries { entries.removeFirst() }
        readout = entries.map { "\($0.sequence) \($0.event.line)" }.joined(separator: "\n")
    }
}
#endif
