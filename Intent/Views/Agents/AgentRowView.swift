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

extension AgentAvatarState {
    /// Corner cue symbol for the needs-user states; nil for the others (the
    /// running dot is drawn separately).
    var cornerSymbol: String? {
        switch self {
        case .question: return "questionmark.bubble.fill"
        case .attentionDiscussion: return AgentAttentionKind.discussion.systemImage
        case .attentionBlocker: return AgentAttentionKind.blocker.systemImage
        case .idle, .running, .waiting, .failed, .completed: return nil
        }
    }

    /// Tint for the corner cue and the matching subtitle line.
    var cornerColor: Color {
        switch self {
        case .attentionBlocker: return AgentAttentionKind.blocker.color
        case .question, .attentionDiscussion: return AgentAttentionKind.discussion.color
        case .idle, .running, .waiting, .failed, .completed: return .secondary
        }
    }
}

struct AgentRowView: View {
    let agent: AgentSession
    let colorScheme: ColorScheme
    var indented: Bool = false
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var avatarState: AgentAvatarState { AgentAvatarState.state(for: agent) }

    var body: some View {
        HStack(spacing: Constants.AgentRow.rowSpacing) {
            // Avatar tile colored by state, with a state-driven corner cue. The
            // needs-user states always keep their symbol (never color alone),
            // so Differentiate Without Color needs no extra branch here.
            ZStack(alignment: .topTrailing) {
                AgentAvatarView(agentId: agent.id, size: Constants.AgentRow.avatarSize,
                                specialist: agent.specialist, isActive: agent.isActive,
                                state: avatarState)

                if avatarState == .running {
                    Circle()
                        .fill(.green)
                        .frame(width: Constants.AgentRow.activeDotSize,
                               height: Constants.AgentRow.activeDotSize)
                        .offset(x: Constants.AgentRow.activeDotOffset,
                                y: -Constants.AgentRow.activeDotOffset)
                } else if let symbol = avatarState.cornerSymbol {
                    Image(systemName: symbol)
                        .font(.system(size: Constants.AgentRow.attentionIconSize))
                        .foregroundStyle(avatarState.cornerColor)
                        .offset(x: Constants.AgentRow.attentionIconOffset,
                                y: -Constants.AgentRow.attentionIconOffset)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(avatarState.accessibilityLabel)

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

                if avatarState == .question {
                    Text(avatarState.accessibilityLabel)
                        .font(.subheadline)
                        .foregroundStyle(avatarState.cornerColor)
                        .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
                } else if avatarState != .running, let attention = agent.pendingAttentionRequest {
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

