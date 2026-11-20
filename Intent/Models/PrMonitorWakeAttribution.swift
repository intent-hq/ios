import Foundation

struct PrMonitorWakeAttribution: Equatable {
    let monitorId: String
    let repo: String
    let prNumber: Int
    let url: String?

    static func from(_ metadata: [String: AnyCodable]) -> Self? {
        guard metadata["type"]?.stringValue == "pr_monitor_wake" else { return nil }
        let repo = (metadata["repo"]?.stringValue ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !repo.isEmpty,
              let prNumber = metadata["prNumber"]?.intValue, prNumber > 0 else { return nil }
        let monitorId = (metadata["monitorId"]?.stringValue ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let rawUrl = (metadata["url"]?.stringValue ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return Self(
            monitorId: monitorId,
            repo: repo,
            prNumber: prNumber,
            url: rawUrl.isEmpty ? nil : rawUrl
        )
    }

    var resolvedUrl: String {
        url ?? "https://github.com/\(repo)/pull/\(prNumber)"
    }

    func chipLabel(workspaceRepo: String?) -> String {
        let number = "#\(prNumber)"
        if let workspaceRepo, repo != workspaceRepo {
            return "\(repo): \(number)"
        }
        return number
    }

    static func stripPrefix(_ text: String) -> String {
        text.replacingOccurrences(
            of: "^\\[PR monitor [^\\]]*\\]\\s*",
            with: "",
            options: .regularExpression
        )
    }

    static func displayText(_ text: String) -> String {
        stripPrefix(text)
    }
}

extension ConversationMessage {
    var prMonitorWakeAttribution: PrMonitorWakeAttribution? {
        if let attribution = PrMonitorWakeAttribution.from(metadata) { return attribution }
        for block in contentBlocks where block.type == .text {
            if let attribution = PrMonitorWakeAttribution.from(block.messageMetadata) {
                return attribution
            }
        }
        return nil
    }
}
