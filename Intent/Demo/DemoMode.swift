import Foundation

/// Demo launches use fixture data and ephemeral persistence without pairing.
/// Demo fixtures exist only in Debug builds; Release ignores the demo flags.
enum DemoMode {
    #if DEBUG
    static let isEnabled = demoDataRequested(by: LaunchOptions.current.arguments)
    static let pretendPaired = pretendPairedRequested(by: LaunchOptions.current.arguments)
    #else
    static let isEnabled = false
    static let pretendPaired = false
    #endif

    static func demoDataRequested(by arguments: [String]) -> Bool {
        #if DEBUG
        arguments.contains("--demo-data")
        #else
        false
        #endif
    }

    static func pretendPairedRequested(by arguments: [String]) -> Bool {
        #if DEBUG
        arguments.contains("--pretend-paired") || demoDataRequested(by: arguments)
        #else
        false
        #endif
    }
}
