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
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        HStack(spacing: Constants.AgentRow.rowSpacing) {
            // Avatar with active indicator
            ZStack(alignment: .topTrailing) {
                AgentAvatarView(agentId: agent.id, size: Constants.AgentRow.avatarSize,
                                specialist: agent.specialist, isActive: agent.isActive)

                if agent.isActive {
                    Circle()
                        .fill(.green)
                        .frame(width: Constants.AgentRow.activeDotSize,
                               height: Constants.AgentRow.activeDotSize)
                        .offset(x: Constants.AgentRow.activeDotOffset,
                                y: -Constants.AgentRow.activeDotOffset)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("Active agent")
                } else if let attention = agent.pendingAttentionRequest {
                    Image(systemName: attention.kind.systemImage)
                        .font(.system(size: Constants.AgentRow.attentionIconSize))
                        .foregroundStyle(attention.kind.color)
                        .offset(x: Constants.AgentRow.attentionIconOffset,
                                y: -Constants.AgentRow.attentionIconOffset)
                }
            }

            VStack(alignment: .leading, spacing: Constants.AgentRow.textSpacing) {
                HStack(spacing: Constants.AgentRow.titleSpacing) {
                    Text(agent.name)
                        .font(.body)
                        .foregroundStyle(Theme.foreground(for: colorScheme))
                        .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)

                    if agent.isBackground {
                        Text("BG")
                            .font(.system(size: Constants.AgentRow.badgeFontSize, weight: .bold))
                            .foregroundStyle(Theme.mutedForeground(
                                for: colorScheme, contrast: colorSchemeContrast))
                            .padding(.horizontal, Constants.AgentRow.badgeHorizontalPadding)
                            .padding(.vertical, Constants.AgentRow.badgeVerticalPadding)
                            .background(Theme.mutedForeground(
                                for: colorScheme, contrast: colorSchemeContrast).opacity(
                                    Constants.AgentRow.badgeBackgroundOpacity))
                            .clipShape(.rect(cornerRadius: Constants.AgentRow.badgeCornerRadius))
                            .overlay {
                                if colorSchemeContrast == .increased {
                                    RoundedRectangle(cornerRadius: Constants.AgentRow.badgeCornerRadius)
                                        .strokeBorder(Theme.border(
                                            for: colorScheme, contrast: colorSchemeContrast))
                                }
                            }
                    }

                    Spacer()

                    if let timestamp = agent.bestTimestamp {
                        Text(relativeDate(from: timestamp))
                            .font(.caption)
                            .foregroundStyle(Theme.mutedForeground(
                                for: colorScheme, contrast: colorSchemeContrast))
                    }
                }

                if let attention = agent.pendingAttentionRequest {
                    Text(attention.reason.map { "\(attention.kind.label) — \($0)" } ?? attention.kind.label)
                        .font(.subheadline)
                        .foregroundStyle(attention.kind.color)
                        .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
                } else if let message = agent.displayMessage {
                    Text(message)
                        .font(.subheadline)
                        .foregroundStyle(Theme.mutedForeground(
                            for: colorScheme, contrast: colorSchemeContrast))
                        .lineLimit(1)
                }
            }
        }
        .padding(.vertical, Constants.AgentRow.verticalPadding)
        .padding(.leading, indented ? Constants.AgentRow.nestedLeadingPadding : 0)
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
            HStack(spacing: Constants.AgentRow.headerSpacing) {
                // Overlapping avatars (up to 5)
                HStack(spacing: Constants.AgentRow.avatarOverlap) {
                    ForEach(Array(agents.prefix(Constants.AgentRow.maximumHeaderAvatars))) { agent in
                        AgentAvatarView(agentId: agent.id, size: Constants.AgentRow.headerAvatarSize,
                                        specialist: agent.specialist)
                    }
                }
                .padding(.leading, Constants.AgentRow.delegatedLeadingPadding)

                Text("\(agents.count) delegated")
                    .font(.caption)
                    .foregroundStyle(Theme.mutedForeground(for: colorScheme))

                Spacer()

                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.caption)
                    .foregroundStyle(Theme.mutedForeground(for: colorScheme))
            }
            .padding(.vertical, Constants.AgentRow.delegatedVerticalPadding)
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
            HStack(spacing: Constants.AgentRow.headerSpacing) {
                HStack(spacing: Constants.AgentRow.avatarOverlap) {
                    ForEach(Array(agents.prefix(Constants.AgentRow.maximumHeaderAvatars))) { agent in
                        AgentAvatarView(agentId: agent.id, size: Constants.AgentRow.headerAvatarSize,
                                        specialist: agent.specialist)
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
            .padding(.vertical, Constants.AgentRow.backgroundVerticalPadding)
        }
        .buttonStyle(.plain)
    }
}

