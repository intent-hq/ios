import SwiftUI

struct WorkspaceRowView: View {
    let workspace: Workspace
    let colorScheme: ColorScheme
    var showRepo: Bool = true

    private var displayStatus: WorkspaceDisplayStatus {
        deriveDisplayStatus(from: workspace)
    }

    private var prPillColor: Color? {
        guard let prStatus = workspace.prStatus else { return nil }
        switch prStatus {
        case "Merged": return .purple
        case "Open": return .green
        case "Draft": return .gray
        case "Closed": return .red
        default: return nil
        }
    }

    private var hasActiveAgents: Bool {
        switch workspace.activity?.lowercased() {
        case "agent_running":
            return true
        case "idle":
            return false
        default:
            // Unknown or nil activity — fall back to agent-summary check
            return workspace.agentSummaryAgents?.contains { $0.isStreaming || $0.isResponding } ?? false
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            // Status icon with agent activity dot overlay
            ZStack(alignment: .topTrailing) {
                statusIcon

                if hasActiveAgents {
                    Circle()
                        .fill(Color.green)
                        .frame(width: 5, height: 5)
                        .offset(x: 2, y: -2)
                }
                // Blue dot removed — it was showing for all workspaces with any agents.
                // In the Electron app, blue = unread messages, which iOS doesn't track yet.
            }

            VStack(alignment: .leading, spacing: 4) {
                if workspace.title.trimmingCharacters(in: .whitespaces).isEmpty {
                    Text("<Untitled>")
                        .font(.body.weight(.medium))
                        .foregroundStyle(Theme.mutedForeground(for: colorScheme))
                        .lineLimit(1)
                } else {
                    Text(workspace.title)
                        .font(.body.weight(.medium))
                        .foregroundStyle(Theme.foreground(for: colorScheme))
                        .lineLimit(1)
                }

                HStack(spacing: 8) {
                    if showRepo, let repo = workspace.repositoryName {
                        Text(repo)
                            .font(.caption)
                            .foregroundStyle(Theme.mutedForeground(for: colorScheme))
                            .lineLimit(1)
                    }

                    if let _ = workspace.prStatus, let pillColor = prPillColor {
                        Text("PR\(workspace.prNumber.map { " #\($0)" } ?? "")")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(pillColor)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(pillColor.opacity(0.12))
                            .clipShape(Capsule())
                    }
                }
            }

            Spacer()

            // Agent indicators (up to 3, active only)
            if let allAgents = workspace.agentSummaryAgents {
                let activeAgents = allAgents.filter { $0.isStreaming || $0.isResponding }
                if !activeAgents.isEmpty {
                    HStack(spacing: -4) {
                        ForEach(Array(activeAgents.prefix(3))) { agent in
                            AuggieAvatarView(seed: agent.id, size: 12, specialist: agent.specialist, isActive: true)
                        }
                    }
                }
            }

            if let activity = workspace.lastActivity ?? workspace.updatedAt {
                Text(relativeDate(from: activity))
                    .font(.caption)
                    .foregroundStyle(Theme.mutedForeground(for: colorScheme))
            }
        }
        .contentShape(Rectangle())
        .padding(.vertical, 6)
        .padding(.horizontal, 4)
        .onAppear {
            #if DEBUG
            print("[WorkspaceRowView] '\(workspace.title)': activity=\(workspace.activity ?? "nil"), agentCount=\(workspace.agentSummaryCount ?? 0), agents=\(workspace.agentSummaryAgents?.count ?? 0), hasActive=\(hasActiveAgents)")
            if let agents = workspace.agentSummaryAgents {
                for agent in agents {
                    print("[WorkspaceRowView]   Agent: \(agent.name) status=\(agent.status) isStreaming=\(agent.isStreaming) isResponding=\(agent.isResponding)")
                }
            }
            #endif
        }
    }

    @ViewBuilder
    private var statusIcon: some View {
        let size: CGFloat = 12
        let color = displayStatus.color

        switch displayStatus {
        case .notStarted:
            // Empty outline circle
            Circle()
                .strokeBorder(Color.gray.opacity(0.4), lineWidth: 1.5)
                .frame(width: size, height: size)

        case .inProgress:
            // Half-filled circle (right half)
            ZStack {
                Circle()
                    .stroke(color, lineWidth: 1.5)
                Circle()
                    .fill(color)
                    .clipShape(HalfCircle())
            }
            .frame(width: size, height: size)

        case .complete:
            // Filled circle with checkmark
            ZStack {
                Circle()
                    .fill(color)
                Image(systemName: "checkmark")
                    .font(.system(size: size * 0.5, weight: .bold))
                    .foregroundColor(.white)
            }
            .frame(width: size, height: size)

        case .prOpen:
            // Filled circle with PR icon
            ZStack {
                Circle()
                    .fill(color)
                Image(systemName: "arrow.triangle.pull")
                    .font(.system(size: size * 0.5, weight: .bold))
                    .foregroundColor(.white)
            }
            .frame(width: size, height: size)

        case .prMerged:
            // Filled circle with merge icon
            ZStack {
                Circle()
                    .fill(color)
                Image(systemName: "arrow.triangle.merge")
                    .font(.system(size: size * 0.5, weight: .bold))
                    .foregroundColor(.white)
            }
            .frame(width: size, height: size)
        }
    }

    private func relativeDate(from isoString: String) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let date = formatter.date(from: isoString) else {
            // Try without fractional seconds
            let basic = ISO8601DateFormatter()
            guard let date = basic.date(from: isoString) else { return isoString }
            return date.relativeFormatted
        }
        return date.relativeFormatted
    }
}

struct HalfCircle: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.addArc(center: CGPoint(x: rect.midX, y: rect.midY),
                     radius: rect.width / 2,
                     startAngle: .degrees(-90),
                     endAngle: .degrees(90),
                     clockwise: false)
        path.closeSubpath()
        return path
    }
}


// MARK: - Relative Date Formatting

extension Date {
    var relativeFormatted: String {
        let interval = Date().timeIntervalSince(self)
        if interval < 60 { return "now" }
        if interval < 3600 { return "\(Int(interval / 60))m" }
        if interval < 86400 { return "\(Int(interval / 3600))h" }
        if interval < 604800 { return "\(Int(interval / 86400))d" }
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        return formatter.string(from: self)
    }
}

