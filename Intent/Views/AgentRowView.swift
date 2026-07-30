import SwiftUI

extension AgentAttentionKind {
    /// Indicator tint: discussion needs input (orange), blocker is stop-flavored (red).
    var color: Color {
        switch self {
        case .discussion: return .orange
        case .blocker: return .red
        }
    }
}

struct AgentRowView: View {
    let agent: AgentSession
    let colorScheme: ColorScheme
    var indented: Bool = false

    var body: some View {
        HStack(spacing: 10) {
            // Avatar with active indicator
            ZStack(alignment: .topTrailing) {
                AuggieAvatarView(seed: agent.id, size: 24, specialist: agent.specialist, isActive: agent.isActive)

                if agent.isActive {
                    Circle()
                        .fill(Color.green)
                        .frame(width: 6, height: 6)
                        .offset(x: 2, y: -2)
                } else if let attention = agent.pendingAttentionRequest {
                    Image(systemName: attention.kind.systemImage)
                        .font(.system(size: 9))
                        .foregroundStyle(attention.kind.color)
                        .offset(x: 3, y: -3)
                }
            }

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(agent.name)
                        .font(.body)
                        .foregroundStyle(Theme.foreground(for: colorScheme))
                        .lineLimit(1)

                    if agent.isBackground {
                        Text("BG")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(Theme.mutedForeground(for: colorScheme))
                            .padding(.horizontal, 4)
                            .padding(.vertical, 2)
                            .background(Theme.mutedForeground(for: colorScheme).opacity(0.15))
                            .cornerRadius(4)
                    }

                    Spacer()

                    if let timestamp = agent.bestTimestamp {
                        Text(relativeDate(from: timestamp))
                            .font(.caption)
                            .foregroundStyle(Theme.mutedForeground(for: colorScheme))
                    }
                }

                if let attention = agent.pendingAttentionRequest {
                    Text(attention.reason.map { "\(attention.kind.label) — \($0)" } ?? attention.kind.label)
                        .font(.subheadline)
                        .foregroundStyle(attention.kind.color)
                        .lineLimit(1)
                } else if let message = agent.displayMessage {
                    Text(message)
                        .font(.subheadline)
                        .foregroundStyle(Theme.mutedForeground(for: colorScheme))
                        .lineLimit(1)
                }
            }
        }
        .padding(.vertical, 6)
        .padding(.leading, indented ? 36 : 0)
    }

    private func relativeDate(from isoString: String) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let date = formatter.date(from: isoString) else {
            let basic = ISO8601DateFormatter()
            guard let date = basic.date(from: isoString) else { return isoString }
            return date.relativeFormatted
        }
        return date.relativeFormatted
    }
}

// MARK: - Collapsible Headers

struct DelegatedAgentsRow: View {
    let agents: [AgentSession]
    let isExpanded: Bool
    let colorScheme: ColorScheme
    let onToggle: () -> Void

    var body: some View {
        Button(action: onToggle) {
            HStack(spacing: 4) {
                // Overlapping avatars (up to 5)
                HStack(spacing: -6) {
                    ForEach(Array(agents.prefix(5))) { agent in
                        AuggieAvatarView(seed: agent.id, size: 16, specialist: agent.specialist)
                    }
                }
                .padding(.leading, 40)

                Text("\(agents.count) delegated")
                    .font(.caption)
                    .foregroundStyle(Theme.mutedForeground(for: colorScheme))

                Spacer()

                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.caption)
                    .foregroundStyle(Theme.mutedForeground(for: colorScheme))
            }
            .padding(.vertical, 4)
        }
        .buttonStyle(.plain)
    }
}

struct BackgroundAgentsHeader: View {
    let agents: [AgentSession]
    let isExpanded: Bool
    let colorScheme: ColorScheme
    let onToggle: () -> Void

    var body: some View {
        Button(action: onToggle) {
            HStack(spacing: 4) {
                HStack(spacing: -6) {
                    ForEach(Array(agents.prefix(5))) { agent in
                        AuggieAvatarView(seed: agent.id, size: 16, specialist: agent.specialist)
                    }
                }

                Text("\(agents.count) background agents")
                    .font(.caption)
                    .foregroundStyle(Theme.mutedForeground(for: colorScheme))

                Spacer()

                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.caption)
                    .foregroundStyle(Theme.mutedForeground(for: colorScheme))
            }
            .padding(.vertical, 8)
        }
        .buttonStyle(.plain)
    }
}

