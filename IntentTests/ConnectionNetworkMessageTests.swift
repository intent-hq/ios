import Foundation
@testable import Intent
import Network
import Testing

@MainActor struct ConnectionNetworkMessageTests {
    @Test(arguments: [NetworkAvailability.Status.unknown, .requiresConnection, .satisfied])
    func uncertainOrAvailablePathIsNotOffline(status: NetworkAvailability.Status) {
        let message = ConnectionNetworkMessage(status: status)
        #expect(!message.isUnavailable)
        #expect(String(localized: message.title) == "Reconnecting…")
        #expect(message.guidance == nil)
    }

    @Test(arguments: [nil, NWPath.UnsatisfiedReason.notAvailable])
    func unsatisfiedPathDoesNotInferAirplaneMode(reason: NWPath.UnsatisfiedReason?) throws {
        let message = ConnectionNetworkMessage(status: .unsatisfied(reason))
        #expect(message.isUnavailable)
        #expect(String(localized: message.title) == "No network connection")
        #expect(String(localized: try #require(message.guidance)) == "Check your Wi-Fi or cellular connection.")
    }

    @Test(arguments: [
        (NWPath.UnsatisfiedReason.localNetworkDenied, "Allow Local Network access for Intent in Settings, then try again."),
        (.cellularDenied, "Allow cellular data for Intent in Settings, or connect to Wi-Fi."),
        (.wifiDenied, "Check Wi-Fi access in Settings, or use cellular data."),
        (.vpnInactive, "Check your VPN connection in Settings.")
    ])
    func reasonSpecificGuidance(reason: NWPath.UnsatisfiedReason, expected: String) throws {
        let message = ConnectionNetworkMessage(status: .unsatisfied(reason))
        #expect(String(localized: try #require(message.guidance)) == expected)
    }
}
