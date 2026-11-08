#if os(iOS)
import Foundation

/// Turns workspace rows from every live backend into Live Activity content.
///
/// Only workspaces seen running while the activity is up appear, so old
/// questions or failures never fill it. A workspace that stops running stays
/// as Done or Failed for `settledRetention`; one that needs the user stays
/// while it does.
struct AgentActivityTracker {
    struct Entry {
        let connectionId: UUID
        let workspace: Workspace
    }

    static let maxRows = 3
    static let settledRetention: TimeInterval = 15 * 60

    private struct Seen {
        var agentId: String?
        var agentName: String?
        var stoppedAt: Date?
    }

    private var seen: [String: Seen] = [:]

    /// Workspaces running now, keyed like `AgentActivityRow.id`.
    private(set) var runningKeys: Set<String> = []

    mutating func reset() {
        seen = [:]
        runningKeys = []
    }

    mutating func content(for entries: [Entry], now: Date) -> AgentActivityAttributes.ContentState {
        var rows: [AgentActivityRow] = []
        var presentKeys: Set<String> = []
        runningKeys = []
        for entry in entries {
            let workspace = entry.workspace
            let key = "\(entry.connectionId.uuidString)/\(workspace.id)"
            presentKeys.insert(key)
            let running = hasRunningAgents(workspace)
            if running {
                runningKeys.insert(key)
                let agent = workspace.agentSummaryAgents.first { $0.isStreaming || $0.isResponding }
                seen[key] = Seen(
                    agentId: agent?.id ?? seen[key]?.agentId,
                    agentName: agent?.name ?? seen[key]?.agentName,
                    stoppedAt: nil
                )
            } else if seen[key]?.stoppedAt == nil {
                seen[key]?.stoppedAt = now
            }
            guard let record = seen[key] else { continue }
            let phase = Self.phase(for: workspace, running: running)
            if phase >= .failed, let stoppedAt = record.stoppedAt,
               now.timeIntervalSince(stoppedAt) > Self.settledRetention {
                seen[key] = nil
                continue
            }
            rows.append(AgentActivityRow(
                connectionId: entry.connectionId,
                workspaceId: workspace.id,
                title: workspace.title,
                detail: workspace.statusMessage.flatMap { $0.isEmpty ? nil : $0 },
                phase: phase,
                agentId: record.agentId,
                agentName: record.agentName
            ))
        }
        seen = seen.filter { presentKeys.contains($0.key) }
        let ordered = rows.enumerated()
            .sorted { ($0.element.phase, $0.offset) < ($1.element.phase, $1.offset) }
            .map(\.element)
        return AgentActivityAttributes.ContentState(
            rows: Array(ordered.prefix(Self.maxRows)),
            runningCount: rows.count(where: { $0.phase == .running }),
            needsYouCount: rows.count(where: { $0.phase == .needsYou }),
            updatedAt: now
        )
    }

    private static func phase(for workspace: Workspace, running: Bool) -> AgentActivityRow.Phase {
        switch workspace.displayStatus {
        case "needs_attention", "blocked": return .needsYou
        default: break
        }
        if workspace.attention == "review_required" { return .needsYou }
        if running { return .running }
        return workspace.displayStatus == "failed" ? .failed : .done
    }
}
#endif
