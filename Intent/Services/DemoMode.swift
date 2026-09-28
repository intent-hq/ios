import Foundation

/// Demo launches use fixture data and ephemeral persistence without pairing.
enum DemoMode {
    static let isEnabled = demoDataRequested(by: ProcessInfo.processInfo.arguments)
    static let pretendPaired = pretendPairedRequested(by: ProcessInfo.processInfo.arguments)

    static func demoDataRequested(by arguments: [String]) -> Bool {
        arguments.contains("--demo-data")
    }

    static func pretendPairedRequested(by arguments: [String]) -> Bool {
        arguments.contains("--pretend-paired") || demoDataRequested(by: arguments)
    }
}
