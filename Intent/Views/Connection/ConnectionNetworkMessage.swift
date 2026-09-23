import Foundation
import Network

/// Copy only. General-path evidence never decides whether remote UI is blocked.
struct ConnectionNetworkMessage {
    let status: NetworkAvailability.Status

    var isUnavailable: Bool {
        if case .unsatisfied = status { return true }
        return false
    }

    var title: LocalizedStringResource {
        isUnavailable ? "No network connection" : "Reconnecting…"
    }

    var guidance: LocalizedStringResource? {
        guard case .unsatisfied(let reason) = status else { return nil }
        switch reason {
        case .localNetworkDenied:
            return "Allow Local Network access for Intent in Settings, then try again."
        case .cellularDenied:
            return "Allow cellular data for Intent in Settings, or connect to Wi-Fi."
        case .wifiDenied:
            return "Check Wi-Fi access in Settings, or use cellular data."
        case .vpnInactive:
            return "Check your VPN connection in Settings."
        default:
            return "Check your Wi-Fi or cellular connection."
        }
    }
}
