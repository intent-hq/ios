import Foundation
import OSLog

/// Debug-only structured logging. Intent emits no production logs; Release
/// builds do not create loggers or evaluate message autoclosures.
nonisolated enum AppLog {
    nonisolated struct Category: Sendable {
        #if DEBUG
        private let logger: Logger
        #endif

        fileprivate init(_ name: String) {
            #if DEBUG
            logger = Logger(
                subsystem: Bundle.main.bundleIdentifier ?? "Intent",
                category: name
            )
            #endif
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
            #if DEBUG
            let renderedMessage = message()
            logger.error("\(renderedMessage, privacy: .public)")
            #endif
        }

        func fault(_ message: @autoclosure () -> String) {
            #if DEBUG
            let renderedMessage = message()
            logger.fault("\(renderedMessage, privacy: .public)")
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
    static let ui = Category("ui")
    static let app = Category("app")
}
