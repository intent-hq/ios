import Foundation

/// Watch metadata describes notification triggers, never the runtime state of a script.
enum ScriptMonitorPresentation {
    static let notificationExplanation = "Notifies the agent when this run finishes or the watch expires."
    static let deadlineReached = "Watch deadline reached; awaiting confirmation"

    static func ownedActive(
        _ monitors: [ScriptMonitorSummary], workspaceId: String, agentId: String
    ) -> [ScriptMonitorSummary] {
        monitors.filter { monitor in
            monitor.workspaceId.utf8.elementsEqual(workspaceId.utf8)
                && monitor.agentId.utf8.elementsEqual(agentId.utf8)
                && monitor.state == "active"
        }
    }

    static func showsStatus(
        hasMonitors: Bool, isLoading: Bool, isStale: Bool, error: String?, nextCursor: String?
    ) -> Bool {
        hasMonitors || isLoading || isStale || error != nil || nextCursor != nil
    }

    static func expiry(_ value: String, now: Date) -> String {
        guard let date = ISO8601DateFormatter.lenientDate(from: value) else { return "Expiry unavailable" }
        guard date > now else { return deadlineReached }
        return "Watch expires in \(DurationFormat.compact(date.timeIntervalSince(now)))"
    }

    static func absoluteDate(
        _ value: String, locale: Locale = .current, timeZone: TimeZone = .current
    ) -> String? {
        guard let date = ISO8601DateFormatter.lenientDate(from: value) else { return nil }
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        formatter.dateStyle = .medium
        formatter.timeStyle = .long
        return formatter.string(from: date)
    }

    static func ownerName(_ name: String?, agentId: String) -> String {
        guard let name, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return agentId }
        return name
    }

    static func lineTrigger(_ count: Int) -> String {
        count == 1 ? "Also notifies after 1 new output line." : "Also notifies after \(count) new output lines."
    }

    struct Pattern: Equatable {
        let label: String
        let value: String
    }

    static func pattern(summary: ScriptMonitorSummary, detail: ScriptMonitorDetail?) -> Pattern? {
        if let detail {
            return detail.outputPattern.map { Pattern(label: "Also notifies when new output matches this pattern", value: $0) }
        }
        return summary.outputPatternPreview.map { preview in
            Pattern(label: "Output pattern preview — full pattern loads with details", value: preview)
        }
    }
}
