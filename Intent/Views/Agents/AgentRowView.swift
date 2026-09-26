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

extension AgentSession {
    /// Context-menu title of the per-agent notification mute toggle.
    var notificationsMuteToggleTitle: String {
        notificationsMuted ? "Unmute notifications" : "Mute notifications"
    }

    /// Context-menu symbol of the per-agent notification mute toggle.
    var notificationsMuteToggleSymbol: String {
        notificationsMuted ? "bell" : "bell.slash"
    }
}

/// Context-menu toggle of the daemon-owned per-agent notification mute
/// (`agent.update { changes: { notificationsMuted } }`). Rendered by the
/// row's containing list so it composes with the row's selection button.
struct AgentNotificationsMuteButton: View {
    let agent: AgentSession
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label {
                Text(agent.notificationsMuteToggleTitle)
                    .interFont(Constants.Typography.bodyS)
            } icon: {
                Image(systemName: agent.notificationsMuteToggleSymbol)
            }
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

    /// The needs-user corner cue (question / discussion / blocker) is the
    /// row's attention badge: a muted agent shows the `bell.slash` glyph by
    /// its name instead. The running dot is activity, not attention, and is
    /// unaffected.
    private var cornerSymbol: String? {
        agent.notificationsMuted ? nil : avatarState.cornerSymbol
    }

    var body: some View {
        HStack(alignment: .top, spacing: Constants.AgentRow.rowSpacing) {
            avatar
            agentDetails
        }
        .padding(.vertical, Constants.AgentRow.verticalPadding)
        .padding(.leading, indented ? Constants.AgentRow.nestedLeadingPadding : 0)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    private var avatar: some View {
        ZStack(alignment: .topTrailing) {
            AgentAvatarView(
                agentId: agent.id,
                size: Constants.AgentRow.avatarSize,
                specialist: agent.specialist,
                isActive: avatarState == .running,
                state: avatarState
            )
            if avatarState == .running {
                Circle()
                    .fill(.green)
                    .frame(
                        width: Constants.AgentRow.activeDotSize,
                        height: Constants.AgentRow.activeDotSize
                    )
                    .offset(x: Constants.AgentRow.activeDotOffset, y: -Constants.AgentRow.activeDotOffset)
            } else if let symbol = cornerSymbol {
                Image(systemName: symbol)
                    .font(.system(size: Constants.AgentRow.attentionIconSize))
                    .foregroundStyle(avatarState.cornerColor)
                    .offset(x: Constants.AgentRow.attentionIconOffset, y: -Constants.AgentRow.attentionIconOffset)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(avatarState.accessibilityLabel)
    }

    private var agentDetails: some View {
        VStack(alignment: .leading, spacing: Constants.AgentRow.textSpacing) {
            titleAndTimestamp
            agentStatusDescription
        }
    }

    @ViewBuilder
    private var agentStatusDescription: some View {
        if avatarState == .question {
            Text(avatarState.accessibilityLabel)
                .interFont(Constants.Typography.bodyXS)
                .foregroundStyle(avatarState.cornerColor)
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
        } else if avatarState != .running, let attention = agent.pendingAttentionRequest {
            Text(attention.reason.map { "\(attention.kind.label) — \($0)" } ?? attention.kind.label)
                .interFont(Constants.Typography.bodyXS)
                .foregroundStyle(attention.kind.color)
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
        } else if let message = agent.displayMessage {
            Text(Self.previewText(message))
                .interFont(Constants.Typography.bodyXS)
                .foregroundStyle(Theme.mutedForeground(
                    for: colorScheme,
                    contrast: colorSchemeContrast
                ))
                .lineLimit(1)
                .allowsHitTesting(false)
        }
    }

    static func previewText(_ message: String) -> AttributedString {
        var text = (try? AttributedString(
            markdown: message,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(message)
        text.link = nil
        return text
    }

    @ViewBuilder
    private var titleAndTimestamp: some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: Constants.AgentRow.textSpacing) {
                agentIdentity
                timestamp
            }
        } else {
            HStack(alignment: .firstTextBaseline, spacing: Constants.AgentRow.titleSpacing) {
                agentIdentity
                Spacer()
                timestamp
            }
        }
    }

    private var agentIdentity: some View {
        HStack(alignment: .firstTextBaseline, spacing: Constants.AgentRow.titleSpacing) {
            Text(agent.name)
                .interFont(Constants.Typography.bodyS)
                .foregroundStyle(Theme.foreground(for: colorScheme))
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
                .layoutPriority(1)

            backgroundBadge
            mutedGlyph
        }
    }

    @ViewBuilder
    private var mutedGlyph: some View {
        if agent.notificationsMuted {
            Image(systemName: "bell.slash")
                .font(.system(size: Constants.AgentRow.badgeFontSize, weight: .semibold))
                .foregroundStyle(Theme.mutedForeground(
                    for: colorScheme,
                    contrast: colorSchemeContrast
                ))
                .accessibilityLabel("Notifications muted")
                .fixedSize()
        }
    }

    @ViewBuilder
    private var backgroundBadge: some View {
        if agent.isBackground {
            Text("BG")
                .interFont(Constants.Typography.Style(
                    face: .bold, size: Constants.AgentRow.badgeFontSize, relativeTo: .caption2
                ))
                .foregroundStyle(Theme.mutedForeground(
                    for: colorScheme,
                    contrast: colorSchemeContrast
                ))
                .padding(.horizontal, Constants.AgentRow.badgeHorizontalPadding)
                .padding(.vertical, Constants.AgentRow.badgeVerticalPadding)
                .background(
                    Theme.mutedForeground(for: colorScheme, contrast: colorSchemeContrast)
                        .opacity(Constants.AgentRow.badgeBackgroundOpacity)
                )
                .clipShape(.rect(cornerRadius: Constants.AgentRow.badgeCornerRadius))
                .overlay {
                    if colorSchemeContrast == .increased {
                        RoundedRectangle(cornerRadius: Constants.AgentRow.badgeCornerRadius)
                            .strokeBorder(Theme.border(
                                for: colorScheme,
                                contrast: colorSchemeContrast
                            ))
                    }
                }
                .fixedSize()
        }
    }

    @ViewBuilder
    private var timestamp: some View {
        if let timestamp = agent.bestTimestamp {
            Text(relativeDate(from: timestamp))
                .interFont(Constants.Typography.subtextXXS)
                .foregroundStyle(Theme.mutedForeground(
                    for: colorScheme,
                    contrast: colorSchemeContrast
                ))
                .fixedSize()
        }
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
            HStack(alignment: .top, spacing: Constants.AgentRow.headerSpacing) {
                summaryLabel
                    .layoutPriority(1)

                Spacer(minLength: Constants.AgentRow.headerSpacing)
                chevron
            }
            .padding(.leading, Constants.AgentRow.avatarSize + Constants.AgentRow.rowSpacing)
            .padding(.vertical, Constants.AgentRow.delegatedVerticalPadding)
            .frame(minHeight: Constants.Accessibility.minimumTapTarget)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(summaryTitle)
        .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
        .visionListRowHitTarget()
    }

    private var summaryLabel: some View {
        Text(summaryTitle)
            .interFont(Constants.Typography.bodyXS)
            .foregroundStyle(Theme.mutedForeground(for: colorScheme))
            .fixedSize(horizontal: false, vertical: true)
    }

    private var chevron: some View {
        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
            .font(.caption)
            .foregroundStyle(Theme.mutedForeground(for: colorScheme))
            .accessibilityHidden(true)
    }

    private var summaryTitle: String {
        let runningCount = agents.count { AgentAvatarState.state(for: $0) == .running }
        return AgentGroupSummary.delegatedRunningTitle(
            runningCount: runningCount,
            totalCount: agents.count
        )
    }
}

enum AgentGroupSummary {
    static func delegatedTitle(count: Int) -> String {
        count == 1 ? "1 delegated agent" : "\(count) delegated agents"
    }

    static func delegatedRunningTitle(runningCount: Int, totalCount: Int) -> String {
        "\(runningCount) of \(delegatedTitle(count: totalCount)) running"
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
                        AgentAvatarView(
                            agentId: agent.id,
                            size: Constants.AgentRow.headerAvatarSize,
                            specialist: agent.specialist,
                            state: AgentAvatarState.state(for: agent)
                        )
                    }
                }

                Text("\(agents.count) background agents")
                    .interFont(Constants.Typography.subtextXXS)
                    .foregroundStyle(Theme.mutedForeground(for: colorScheme))

                Spacer()

                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.caption)
                    .foregroundStyle(Theme.mutedForeground(for: colorScheme))
                    .accessibilityHidden(true)
            }
            .padding(.vertical, Constants.AgentRow.backgroundVerticalPadding)
        }
        .buttonStyle(.plain)
        .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
        .visionListRowHitTarget()
    }
}
