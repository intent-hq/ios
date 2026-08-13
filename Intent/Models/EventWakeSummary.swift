import Foundation

/// Short human label + muted report preview for a workspace
/// event-notification wake (`[WORKSPACE EVENTS]`).
struct EventWakeSummary: Equatable {
    let label: String
    let preview: String?
}

/// Dependency-light helpers for detecting and summarizing workspace event
/// wakes (FE parity: `event-wake-summary.ts` / `QueuedMessageList`).
enum EventWake {
    /// An agent lifecycle event parsed from a wake's metadata or text.
    struct ParsedAgentEvent: Equatable {
        let type: String
        let agentId: String
        let agentName: String?
        let completionReport: String?
        let lastResponseSummary: String?
    }

    /// Event types that mean a child agent finished its work.
    private static let completionEventTypes: Set<String> = ["agent:idle", "agent:reportToParent"]
    private static let previewMaxLength = 120

    /// Whether an entry is a system event-notification wake. Metadata-first
    /// (`type == "event_notification"`), with the `[WORKSPACE EVENTS]`
    /// content prefix as fallback for daemons that don't send queue metadata.
    static func isEventNotification(content: String, metadata: [String: AnyCodable]?) -> Bool {
        if metadata?["type"]?.stringValue == "event_notification" { return true }
        return content.hasPrefix("[WORKSPACE EVENTS]")
    }

    /// First value that is a non-empty (non-whitespace) string, if any.
    private static func firstNonEmptyString(_ values: Any?...) -> String? {
        for value in values {
            if let string = value as? String,
               !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return string
            }
        }
        return nil
    }

    /// Parse agent events from the wake's metadata (preferred — carries
    /// completion reports) or, when structured events are absent, from the
    /// numbered lines of the message text (legacy support). Deduplicates by
    /// agentId; later events override earlier ones, first-seen order kept.
    static func parseAgentEvents(content: String, metadata: [String: AnyCodable]?) -> [ParsedAgentEvent] {
        var order: [String] = []
        var byId: [String: ParsedAgentEvent] = [:]
        func upsert(_ event: ParsedAgentEvent) {
            if byId[event.agentId] == nil { order.append(event.agentId) }
            byId[event.agentId] = event
        }

        if let events = metadata?["events"]?.arrayValue, !events.isEmpty {
            for item in events {
                guard let event = item as? [String: Any],
                      let type = event["type"] as? String,
                      let data = event["data"] as? [String: Any],
                      let agentId = data["agentId"] as? String,
                      completionEventTypes.contains(type) || type == "agent:created"
                else { continue }
                upsert(ParsedAgentEvent(
                    type: type, agentId: agentId,
                    agentName: data["agentName"] as? String,
                    completionReport: firstNonEmptyString(data["completionReport"], data["report"]),
                    lastResponseSummary: firstNonEmptyString(data["lastResponseSummary"])))
            }
            return order.compactMap { byId[$0] }
        }

        guard !content.isEmpty else { return [] }
        for line in content.split(separator: "\n", omittingEmptySubsequences: false) {
            guard let match = line.firstMatch(of: #/^\d+\.\s*\[([^\]]+)\]\s*(.+)$/#) else { continue }
            let type = String(match.1)
            let rawSummary = String(match.2)
            var agentId = rawSummary.firstMatch(of: #/\{\{agentId:([^}]+)\}\}/#).map { String($0.1) }
            if agentId == nil {
                agentId = rawSummary
                    .firstMatch(of: #/\((agent-[a-f0-9-]+)\)/#.ignoresCase())
                    .map { String($0.1) }
            }
            guard let agentId,
                  completionEventTypes.contains(type) || type == "agent:created"
            else { continue }
            let agentName = rawSummary.firstMatch(of: #/"([^"]+)"/#).map { String($0.1) }
            upsert(ParsedAgentEvent(type: type, agentId: agentId, agentName: agentName,
                                    completionReport: nil, lastResponseSummary: nil))
        }
        return order.compactMap { byId[$0] }
    }

    /// Ordered mapping of non-agent event-type prefixes to category labels.
    private static let categoryLabels: [(prefix: String, label: String)] = [
        ("file:", "file changes"),
        ("task:", "task updates"),
        ("note:", "note changes"),
        ("git:", "git activity"),
        ("terminal:", "terminal activity"),
        ("test:", "test activity"),
        ("build:", "build activity"),
        ("comment:", "comment updates"),
        ("workspace:", "workspace updates"),
        ("spec:", "spec updates"),
        ("goal:", "goal updates"),
    ]

    /// Map non-agent event types to category labels (e.g. "file changes").
    static func categorizeEventTypes(_ types: [String]) -> [String] {
        categoryLabels
            .filter { entry in types.contains { $0.hasPrefix(entry.prefix) } }
            .map { $0.label }
    }

    private static func truncatePreview(_ text: String) -> String {
        text.count > previewMaxLength
            ? String(text.prefix(previewMaxLength - 1)) + "…"
            : text
    }

    /// Numbered event lines from the wake text, without the "N. " prefix.
    private static func extractEventLines(_ content: String) -> [String] {
        content.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { $0.firstMatch(of: #/^\d+\.\s*\[[^\]]+\]/#) != nil }
            .map {
                String($0).replacingOccurrences(
                    of: "^\\d+\\.\\s*", with: "", options: .regularExpression)
            }
    }

    /// Short human label + muted report preview for an event-notification
    /// wake. Agent events get named labels; non-agent events get category
    /// labels derived from `metadata.eventTypes`; otherwise falls back to an
    /// event count. Legacy wakes without structured metadata get a truncated
    /// first-event-line preview.
    static func summarize(content: String, metadata: [String: AnyCodable]?) -> EventWakeSummary {
        let events = parseAgentEvents(content: content, metadata: metadata)
        let completed = events.filter { completionEventTypes.contains($0.type) }
        let created = events.filter { $0.type == "agent:created" }
        var parts: [String] = []
        if completed.count == 1 {
            parts.append("Child agent \(completed[0].agentName ?? completed[0].agentId) completed")
        } else if completed.count > 1 {
            parts.append("\(completed.count) child agents completed")
        }
        if created.count == 1 {
            parts.append("Child agent \(created[0].agentName ?? created[0].agentId) created")
        } else if created.count > 1 {
            parts.append("\(created.count) child agents created")
        }

        let types = (metadata?["eventTypes"]?.arrayValue ?? []).compactMap { $0 as? String }
        parts.append(contentsOf: categorizeEventTypes(types))

        let eventLines = extractEventLines(content)
        let label: String
        if !parts.isEmpty {
            label = parts.joined(separator: " · ")
        } else {
            let metaCount = metadata?["eventCount"]?.intValue ?? 0
            let structuredCount = metadata?["events"]?.arrayValue?.count ?? 0
            let count = metaCount > 0
                ? metaCount
                : (structuredCount > 0 ? structuredCount : eventLines.count)
            label = count > 0
                ? "\(count) workspace event\(count == 1 ? "" : "s")"
                : "Workspace events"
        }

        let withReport = completed.first { $0.completionReport != nil || $0.lastResponseSummary != nil }
        var preview = withReport?.completionReport ?? withReport?.lastResponseSummary
        if preview == nil, parts.isEmpty {
            if let firstEventLine = eventLines.first {
                preview = truncatePreview(firstEventLine)
            } else {
                // Rust daemon wakes are a single unnumbered
                // "[WORKSPACE EVENTS] …" line; strip the prefix and skip the
                // generic wake-header boilerplate.
                let firstLine = (content.split(
                    separator: "\n", omittingEmptySubsequences: false).first.map(String.init) ?? "")
                    .replacingOccurrences(
                        of: "^\\[WORKSPACE EVENTS\\]\\s*", with: "", options: .regularExpression)
                    .trimmingCharacters(in: .whitespaces)
                if !firstLine.isEmpty,
                   firstLine.range(
                       of: "^You have been woken up by",
                       options: [.regularExpression, .caseInsensitive]) == nil {
                    preview = truncatePreview(firstLine)
                }
            }
        }
        return EventWakeSummary(label: label, preview: preview)
    }
}

extension QueuedMessage {
    /// Whether this queued entry is a system event-notification wake
    /// (`messageMetadata.type == "event_notification"`, with the
    /// `[WORKSPACE EVENTS]` content prefix as fallback).
    var isEventNotificationWake: Bool {
        EventWake.isEventNotification(content: content, metadata: messageMetadata)
    }

    /// Summary label + preview for an event-notification wake entry.
    var eventWakeSummary: EventWakeSummary {
        EventWake.summarize(content: content, metadata: messageMetadata)
    }
}
