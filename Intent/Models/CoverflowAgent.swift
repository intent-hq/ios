import Foundation
import SwiftUI

/// Wraps an `AgentSession` with cross-workspace metadata and queue state
/// for the Coverflow view.
struct CoverflowAgent: Identifiable, Equatable {
    let id: String              // agentId
    let agent: AgentSession
    let workspaceId: String
    let repositoryName: String
    let repositoryOwner: String?
    let workspaceTitle: String

    /// Queue state — UI-only flags, not persisted to the server.
    var isDismissed: Bool = false
    var isBanished: Bool = false

    // MARK: - Deterministic colors (stable across app runs)

    /// Repo color derived from workspace ID using stable djb2 hash.
    var repoColor: Color {
        let hue = Double(RepoColorSystem.stableHash(workspaceId) % 360) / 360.0
        return Color(hue: hue, saturation: 0.5, brightness: 0.85)
    }

    /// Agent color derived from agent ID using stable djb2 hash.
    var agentColor: Color {
        let hue = Double(RepoColorSystem.stableHash(id) % 360) / 360.0
        return Color(hue: hue, saturation: 0.5, brightness: 0.85)
    }

    // MARK: - Convenience

    var isIdle: Bool {
        !agent.isActive
    }

    var name: String { agent.name }
    var status: String { agent.status }
    var specialist: String? { agent.specialist }

    /// Parse an ISO8601 date string, handling both with and without fractional seconds.
    private static func parseDate(_ raw: String) -> Date? {
        let frac = ISO8601DateFormatter()
        frac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = frac.date(from: raw) { return d }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: raw)
    }

    /// Best timestamp for sorting — prefer updatedAt, then lastActivity, then createdAt.
    var bestTimestamp: Date? {
        guard let raw = agent.bestTimestamp else { return nil }
        return Self.parseDate(raw)
    }

    /// Last activity date for computing idle duration.
    var lastActivityDate: Date? {
        let raw = agent.lastActivity ?? agent.updatedAt ?? agent.createdAt
        guard let raw else { return nil }
        return Self.parseDate(raw)
    }

    /// Human-readable idle duration string like "idle 5m" or "idle 2h".
    /// Returns "idle" with no duration if no date could be parsed.
    var idleString: String? {
        guard isIdle else { return nil }
        guard let lastDate = lastActivityDate else { return "idle" }
        let elapsed = Date().timeIntervalSince(lastDate)
        if elapsed < 60 { return "idle <1m" }
        if elapsed < 3600 {
            let minutes = Int(elapsed / 60)
            return "idle \(minutes)m"
        }
        if elapsed < 86400 {
            let hours = Int(elapsed / 3600)
            return "idle \(hours)h"
        }
        let days = Int(elapsed / 86400)
        return "idle \(days)d"
    }
}

