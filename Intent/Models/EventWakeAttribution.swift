import Foundation

/// Attribution for event-subscription wake messages (agent wakes). The daemon
/// tags user-role rows delivered by an event-notification wake with
/// `{ type: "event_notification", eventCount, eventTypes, events? }` — on the
/// row's `metadata` and on the persisted text block's `messageMetadata`.
/// Extraction is metadata-first with graceful fallback: absent or malformed
/// metadata returns nil so the message renders exactly as before (FE parity:
/// `EventWakeupBanner.svelte`).
struct EventWakeAttribution: Equatable {
    private static let summaryEventCountThreshold = 5

    /// One structured event from the wake's `events` payload.
    struct Event: Equatable {
        let type: String
        /// Display name of the event's agent, when the payload carries a
        /// non-id-shaped `agentName` / `name` field. Nil otherwise so labels
        /// fall back to generic wording instead of rendering a raw agent id.
        let agentName: String?
    }

    /// Number of events in the wake (falls back to the events / eventTypes
    /// length when the daemon omitted the count).
    let eventCount: Int
    /// Raw event types (e.g. `agent:idle`, `file:changed`).
    let eventTypes: [String]
    /// Structured events, when the daemon included them (may be empty).
    let events: [Event]

    /// Extracts event-wake attribution from an opaque metadata dictionary.
    /// Returns nil unless `metadata.type == "event_notification"`.
    static func from(_ metadata: [String: AnyCodable]) -> Self? {
        guard metadata["type"]?.stringValue == "event_notification" else { return nil }
        let rawEventTypes: [Any]
        if case let .value(values) = metadata["eventTypes"]?.arrayValue { rawEventTypes = values } else { rawEventTypes = [] }
        let eventTypes = rawEventTypes.compactMap { $0 as? String }
        let rawEvents: [Any]
        if case let .value(values) = metadata["events"]?.arrayValue { rawEvents = values } else { rawEvents = [] }
        let events: [Event] = rawEvents.compactMap { raw in
            guard let dict = raw as? [String: Any],
                  let type = dict["type"] as? String else { return nil }
            let data = dict["data"] as? [String: Any] ?? [:]
            return Event(type: type, agentName: resolveAgentName(data))
        }
        let eventCount = metadata["eventCount"]?.intValue
            ?? (events.isEmpty ? eventTypes.count : events.count)
        return Self(
            eventCount: eventCount,
            eventTypes: eventTypes,
            events: events
        )
    }

    /// Compact human summary of the wake, in daemon order. Large bursts stay
    /// count-only; small wakes list deduplicated per-event labels (FE parity:
    /// EventWakeupBanner `friendlySummary`).
    var summaryLabel: String {
        if eventCount >= Self.summaryEventCountThreshold { return "\(eventCount) events" }
        let sources = events.isEmpty
            ? eventTypes.map { Event(type: $0, agentName: nil) }
            : events
        if sources.isEmpty { return "Subscription update" }
        var labels: [String] = []
        var seen = Set<String>()
        for event in sources {
            let label = Self.activityLabel(for: event)
            if seen.insert(label).inserted { labels.append(label) }
        }
        return labels.joined(separator: ", ")
    }

    /// Human label for one event: agent lifecycle events name the agent when
    /// the payload carries a usable name; everything else maps to its
    /// category label (FE parity: activity-labels + event-wake-summary).
    static func activityLabel(for event: Event) -> String {
        let name = event.agentName
        switch event.type {
        case "agent:idle":
            return name.map { "\($0) finished" } ?? "Agent finished"
        case "agent:reportToParent":
            return name.map { "\($0) sent a message" } ?? "Agent sent a message"
        case "agent:completed":
            return name.map { "\($0) completed" } ?? "Agent completed"
        case "agent:failed":
            return name.map { "\($0) failed" } ?? "Agent failed"
        case "agent:created":
            return name.map { "Created agent \($0)" } ?? "New agent created"
        default:
            return categoryLabel(for: event.type) ?? humanized(event.type)
        }
    }

    /// Humanizes an unmapped wire type so machine identifiers never surface
    /// verbatim in the banner (FE parity: `getActivityLabel` default) —
    /// `custom:thing` → "Custom thing".
    private static func humanized(_ type: String) -> String {
        let words = type
            .replacingOccurrences(of: ":", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "_", with: " ")
            .trimmingCharacters(in: .whitespaces)
        guard let first = words.first else { return type }
        return first.uppercased() + words.dropFirst()
    }

    /// Ordered mapping of non-agent event-type prefixes to category labels
    /// (FE parity: event-wake-summary `EVENT_CATEGORY_LABELS`).
    private static let categoryLabels: [(prefix: String, label: String)] = [
        ("file:", "File changes"),
        ("task:", "Task updates"),
        ("note:", "Note changes"),
        ("git:", "Git activity"),
        ("terminal:", "Terminal activity"),
        ("test:", "Test activity"),
        ("build:", "Build activity"),
        ("comment:", "Comment updates"),
        ("workspace:", "Workspace updates"),
        ("spec:", "Spec updates"),
        ("goal:", "Goal updates")
    ]

    private static func categoryLabel(for type: String) -> String? {
        categoryLabels.first { type.hasPrefix($0.prefix) }?.label
    }

    /// Best display name for an event's agent: `agentName`, else `name` —
    /// never an id-shaped value (FE parity: `resolveAgentName`, minus the
    /// live session-store lookup, which iOS does not keep per-message).
    private static func resolveAgentName(_ data: [String: Any]) -> String? {
        for key in ["agentName", "name"] {
            guard let value = data[key] as? String else { continue }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty, !looksLikeAgentId(trimmed) { return AgentSession.displayName(for: trimmed) }
        }
        return nil
    }

    /// Whether a string is agent-id-shaped (`agent-<uuid>`), so id values
    /// leaking into name fields never render as display names.
    static func looksLikeAgentId(_ value: String) -> Bool {
        value.range(
            of: "^agent-[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$",
            options: .regularExpression
        ) != nil
    }
}

extension ConversationMessage {
    /// Event-wake attribution for this row: the daemon tags the row's
    /// `metadata` AND the persisted text block's `messageMetadata` — check
    /// both so older rows missing one surface still render the banner
    /// (FE parity: ChatPanel.svelte event-notification turn branch).
    var eventWakeAttribution: EventWakeAttribution? {
        if let attribution = EventWakeAttribution.from(metadata) { return attribution }
        for block in contentBlocks where block.type == .text {
            if let attribution = EventWakeAttribution.from(block.messageMetadata) {
                return attribution
            }
        }
        // Legacy rows carry no metadata, only the machine-text prefix. Fall
        // back to an empty attribution so the banner (generic label) replaces
        // the raw machine text (FE parity: `isEventWakeMessage`).
        let text = contentBlocks
            .first { $0.type == .text }?
            .resolvedText?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if text.hasPrefix("[WORKSPACE EVENTS]") {
            return EventWakeAttribution(eventCount: 0, eventTypes: [], events: [])
        }
        return nil
    }
}
