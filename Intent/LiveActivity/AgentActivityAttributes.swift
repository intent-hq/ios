import Foundation
#if os(iOS)
import ActivityKit
#endif

nonisolated struct AgentActivityRow: Codable, Hashable, Identifiable, Sendable {
    let connectionId: UUID
    let workspaceId: String
    let title: String
    let detail: String?
    let agentId: String?
    let agentName: String?
    var kind: AgentActivityNoticeKind?

    var id: String { "\(connectionId.uuidString)/\(workspaceId)" }

    var link: AgentActivityLink? {
        guard let agentId else { return nil }
        return AgentActivityLink(
            connectionId: connectionId,
            workspaceId: workspaceId,
            agentId: agentId,
            agentName: agentName ?? "Agent"
        )
    }
}

nonisolated enum AgentActivityNoticeKind: String, Codable, Hashable, Sendable {
    case finished
    case needsAttention = "needs_attention"
    case reviewRequired = "review_required"

    init(from decoder: any Decoder) throws {
        self = Self(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .finished
    }
}

nonisolated struct AgentActivityLink: Equatable, Sendable {
    static let host = "agent"

    let connectionId: UUID
    let workspaceId: String
    let agentId: String
    let agentName: String

    var url: URL? {
        var components = URLComponents()
        components.scheme = "intent"
        components.host = Self.host
        components.queryItems = [
            URLQueryItem(name: "connection", value: connectionId.uuidString),
            URLQueryItem(name: "workspace", value: workspaceId),
            URLQueryItem(name: "agent", value: agentId),
            URLQueryItem(name: "name", value: agentName)
        ]
        return components.url
    }

    init(connectionId: UUID, workspaceId: String, agentId: String, agentName: String) {
        self.connectionId = connectionId
        self.workspaceId = workspaceId
        self.agentId = agentId
        self.agentName = agentName
    }

    init?(url: URL) {
        guard url.scheme == "intent", url.host == Self.host,
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
        else { return nil }
        func value(_ name: String) -> String? {
            items.first { $0.name == name }?.value.flatMap { $0.isEmpty ? nil : $0 }
        }
        guard let connection = value("connection").flatMap(UUID.init(uuidString:)),
              let workspaceId = value("workspace"),
              let agentId = value("agent")
        else { return nil }
        self.init(
            connectionId: connection,
            workspaceId: workspaceId,
            agentId: agentId,
            agentName: value("name") ?? "Agent"
        )
    }
}

#if os(iOS)
nonisolated struct AgentActivityAttributes: ActivityAttributes, Sendable {
    nonisolated struct ContentState: Codable, Hashable, Sendable {
        var rows: [AgentActivityRow]
        var runningCount: Int
        var updatedAt: Double
        var finished: AgentActivityRow?

        var updatedDate: Date { Date(timeIntervalSince1970: updatedAt) }
    }
}
#endif
