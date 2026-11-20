import Foundation

struct ScriptMonitorWakeAttribution: Equatable {
    enum Reason: String {
        case finished
        case ttlExpired = "ttl-expired"
        case outputMatch = "output-match"
        case lineCount = "line-count"
    }

    let scriptName: String
    let scriptId: String
    let runId: String
    let monitorId: String
    let workspaceId: String
    let reason: Reason
    let matchedLine: String?

    static func from(_ metadata: [String: AnyCodable]) -> Self? {
        guard metadata["type"]?.stringValue == "script_monitor_wake",
              metadata["source"]?.stringValue == "system",
              let scriptName = metadata["scriptName"]?.stringValue,
              let scriptId = nonEmpty(metadata["scriptId"]),
              let runId = nonEmpty(metadata["runId"]),
              let monitorId = nonEmpty(metadata["monitorId"]),
              let workspaceId = nonEmpty(metadata["workspaceId"]),
              let reason = metadata["reason"]?.stringValue.flatMap(Reason.init(rawValue:))
        else { return nil }
        var matchedLine: String?
        if reason == .outputMatch, case let .value(trigger) = metadata["trigger"]?.dictValue {
            matchedLine = trigger["matchedLine"] as? String
        }
        return Self(
            scriptName: scriptName,
            scriptId: scriptId,
            runId: runId,
            monitorId: monitorId,
            workspaceId: workspaceId,
            reason: reason,
            matchedLine: matchedLine
        )
    }

    var statusLabel: String {
        switch reason {
        case .finished: "Run finished; agent notified"
        case .ttlExpired: "Monitoring expired; script left running"
        case .outputMatch: "Line matched; monitoring ended"
        case .lineCount: "Line threshold reached; monitoring ended"
        }
    }

    private static func nonEmpty(_ value: AnyCodable?) -> String? {
        guard let string = value?.stringValue, !string.isEmpty else { return nil }
        return string
    }
}

extension ConversationMessage {
    var scriptMonitorWakeAttribution: ScriptMonitorWakeAttribution? {
        if let attribution = ScriptMonitorWakeAttribution.from(metadata) { return attribution }
        for block in contentBlocks where block.type == .text {
            if let attribution = ScriptMonitorWakeAttribution.from(block.messageMetadata) {
                return attribution
            }
        }
        return nil
    }
}
