import Foundation

struct EventWakeAttribution: Equatable {
    private static let summaryEventCountThreshold = 5

    struct Event: Equatable {
        let type: String
        let agentName: String?
    }

    let eventCount: Int
    let eventTypes: [String]
    let events: [Event]

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

    var summaryLabel: String {
        if eventCount >= Self.summaryEventCountThreshold { return "\(eventCount) events" }
        let sources = events.isEmpty
            ? eventTypes.map { Event(type: $0, agentName: nil) }
            : events
        if sources.isEmpty { return "Subscription update" }
        var labels: [String] = []
        var seen = Set<String>()
        var previousAgent: String?
        for event in sources {
            let label = Self.activityLabel(for: event)
            guard seen.insert(label).inserted else { continue }
            if let name = event.agentName, let action = Self.agentAction(for: event.type) {
                if previousAgent == name, !labels.isEmpty {
                    labels[labels.count - 1] += " and \(action)"
                } else {
                    labels.append(label)
                }
                previousAgent = name
            } else {
                labels.append(label)
                previousAgent = nil
            }
        }
        return labels.joined(separator: ", ")
    }

    static func activityLabel(for event: Event) -> String {
        let name = event.agentName
        if let action = agentAction(for: event.type) {
            return "\(name ?? "Agent") \(action)"
        }
        switch event.type {
        case "agent:created":
            return name.map { "Created agent \($0)" } ?? "New agent created"
        default:
            return categoryLabel(for: event.type) ?? humanized(event.type)
        }
    }

    private static func agentAction(for type: String) -> String? {
        switch type {
        case "agent:idle":
            return "finished"
        case "agent:reportToParent":
            return "sent a message"
        case "agent:completed":
            return "completed"
        case "agent:failed":
            return "failed"
        default:
            return nil
        }
    }

    private static func humanized(_ type: String) -> String {
        let words = type
            .replacingOccurrences(of: ":", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "_", with: " ")
            .trimmingCharacters(in: .whitespaces)
        guard let first = words.first else { return type }
        return first.uppercased() + words.dropFirst()
    }

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

    private static func resolveAgentName(_ data: [String: Any]) -> String? {
        for key in ["agentName", "name"] {
            guard let value = data[key] as? String else { continue }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty, !looksLikeAgentId(trimmed) { return AgentSession.displayName(for: trimmed) }
        }
        return nil
    }

    static func looksLikeAgentId(_ value: String) -> Bool {
        value.range(
            of: "^agent-[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$",
            options: .regularExpression
        ) != nil
    }
}

extension ConversationMessage {
    var eventWakeAttribution: EventWakeAttribution? {
        if let attribution = EventWakeAttribution.from(metadata) { return attribution }
        for block in contentBlocks where block.type == .text {
            if let attribution = EventWakeAttribution.from(block.messageMetadata) {
                return attribution
            }
        }
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
