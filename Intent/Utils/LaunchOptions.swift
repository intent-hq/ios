import Foundation

/// Launch arguments and environment, read once per process so app code does
/// not query `ProcessInfo` for flags directly.
nonisolated struct LaunchOptions: Sendable {
    static let current = Self(
        arguments: ProcessInfo.processInfo.arguments,
        environment: ProcessInfo.processInfo.environment
    )

    let arguments: [String]
    let environment: [String: String]

    init(arguments: [String], environment: [String: String] = [:]) {
        self.arguments = arguments
        self.environment = environment
    }

    func contains(_ argument: String) -> Bool {
        arguments.contains(argument)
    }

    /// True inside an XCTest host or an Xcode preview process.
    var isTestOrPreviewHost: Bool {
        environment["XCTestConfigurationFilePath"] != nil
            || environment["XCODE_RUNNING_FOR_PREVIEWS"] == "1"
    }
}
