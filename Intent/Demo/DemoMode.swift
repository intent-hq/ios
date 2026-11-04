import Foundation

/// Demo launches use fixture data and ephemeral persistence without pairing.
enum DemoMode {
    static let isEnabled = demoDataRequested(by: LaunchOptions.current.arguments)
    static let pretendPaired = pretendPairedRequested(by: LaunchOptions.current.arguments)

    static func demoDataRequested(by arguments: [String]) -> Bool {
        arguments.contains("--demo-data")
    }

    static func pretendPairedRequested(by arguments: [String]) -> Bool {
        arguments.contains("--pretend-paired") || demoDataRequested(by: arguments)
    }
}
