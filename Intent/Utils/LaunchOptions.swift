import Foundation

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

    var isTestOrPreviewHost: Bool {
        environment["XCTestConfigurationFilePath"] != nil
            || environment["XCODE_RUNNING_FOR_PREVIEWS"] == "1"
    }
}
