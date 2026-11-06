import Foundation
import OSLog

/// Explicitly enabled diagnostics in both Debug and Release. Details must contain
/// only identifiers, counts, timings and fixed reasons, never transcript content.
nonisolated enum ConversationTrace {
    static let enabled = LaunchOptions.current.environment["INTENT_CONVERSATION_TRACE"] == "1"
        || LaunchOptions.current.contains("--trace-conversation")

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "Intent",
        category: "ConversationTrace"
    )
    private static let signposter = OSSignposter(logger: logger)
    private static let session = UUID().uuidString
    private static let metadataLengthLimit = 64
    private static let activation: Void = {
        let environment = LaunchOptions.current.environment
        let bundle = Bundle.main
        #if DEBUG
        let configuration = "Debug"
        #else
        let configuration = "Release"
        #endif
        let version = token(bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)
        let build = token(bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String)
        let source = token(environment["INTENT_TRACE_SOURCE_SHA"]
            ?? bundle.object(forInfoDictionaryKey: "IntentBuildSHA") as? String)
        let fields = stamped(
            "version=\(version) build=\(build) configuration=\(configuration) sourceSHA=\(source) pid=\(ProcessInfo.processInfo.processIdentifier)"
        )
        logger.notice("event=TraceEnabled \(fields, privacy: .public)")
        signposter.emitEvent("TraceEnabled", "\(fields, privacy: .public)")
    }()

    static func emit(_ name: StaticString, _ detail: @autoclosure () -> String) {
        guard enabled else { return }
        _ = activation
        let fields = stamped(detail())
        let event = String(describing: name)
        logger.notice("event=\(event, privacy: .public) \(fields, privacy: .public)")
        signposter.emitEvent(name, "\(fields, privacy: .public)")
    }

    static func begin(_ name: StaticString, _ detail: @autoclosure () -> String) -> OSSignpostIntervalState? {
        guard enabled else { return nil }
        _ = activation
        let fields = stamped(detail())
        let interval = signposter.beginInterval(name, id: signposter.makeSignpostID(), "\(fields, privacy: .public)")
        let event = String(describing: name)
        let identifier = String(describing: ObjectIdentifier(interval))
        logger.notice("event=\(event, privacy: .public) phase=begin interval=\(identifier, privacy: .public) \(fields, privacy: .public)")
        return interval
    }

    static func end(
        _ name: StaticString,
        _ interval: OSSignpostIntervalState?,
        _ detail: @autoclosure () -> String
    ) {
        guard enabled, let interval else { return }
        let fields = stamped(detail())
        let event = String(describing: name)
        let identifier = String(describing: ObjectIdentifier(interval))
        signposter.endInterval(name, interval, "\(fields, privacy: .public)")
        logger.notice("event=\(event, privacy: .public) phase=end interval=\(identifier, privacy: .public) \(fields, privacy: .public)")
    }

    private static func stamped(_ detail: String) -> String {
        "uptime=\(ProcessInfo.processInfo.systemUptime) session=\(session) \(detail)"
    }

    private static func token(_ value: String?) -> String {
        guard let value, !value.isEmpty else { return "unknown" }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        return String(value.unicodeScalars.prefix(metadataLengthLimit).map { allowed.contains($0) ? Character($0) : "_" })
    }
}
