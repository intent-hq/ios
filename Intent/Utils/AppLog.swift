import Foundation
import OSLog

/// Structured logging with debug-only lower levels. Release builds compile out
/// debug through warning, while error and fault remain active with private messages.
nonisolated enum AppLog {
    nonisolated struct Category: Sendable {
        private let logger: Logger

         init(_ name: String) {
            logger = Logger(
                subsystem: Bundle.main.bundleIdentifier ?? "Intent",
                category: name
            )
        }

        func debug(_ message: @autoclosure () -> String) {
            #if DEBUG
            let renderedMessage = message()
            logger.debug("\(renderedMessage, privacy: .public)")
            #endif
        }

        func info(_ message: @autoclosure () -> String) {
            #if DEBUG
            let renderedMessage = message()
            logger.info("\(renderedMessage, privacy: .public)")
            #endif
        }

        func notice(_ message: @autoclosure () -> String) {
            #if DEBUG
            let renderedMessage = message()
            logger.notice("\(renderedMessage, privacy: .public)")
            #endif
        }

        func warning(_ message: @autoclosure () -> String) {
            #if DEBUG
            let renderedMessage = message()
            logger.warning("\(renderedMessage, privacy: .public)")
            #endif
        }

        func error(_ message: @autoclosure () -> String) {
            let renderedMessage = message()
            #if DEBUG
            logger.error("\(renderedMessage, privacy: .public)")
            #else
            logger.error("\(renderedMessage, privacy: .private)")
            #endif
        }

        func fault(_ message: @autoclosure () -> String) {
            let renderedMessage = message()
            #if DEBUG
            logger.fault("\(renderedMessage, privacy: .public)")
            #else
            logger.fault("\(renderedMessage, privacy: .private)")
            #endif
        }
    }

    static let connection = Category("connection")
    static let conversation = Category("conversation")
    static let workspace = Category("workspace")
    static let notes = Category("notes")
    static let tasks = Category("tasks")
    static let comments = Category("comments")
    static let prs = Category("prs")
    static let github = Category("github")
    static let hooks = Category("hooks")
    static let agents = Category("agents")
    static let notifications = Category("notifications")
    static let userInterface = Category("ui")
    static let app = Category("app")
}
