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
    /// Discussion and blocker cues; questions use the row's status text.
    var cornerIcon: String? {
        switch self {
        case .attentionDiscussion: return AgentAttentionKind.discussion.iconName
        case .attentionBlocker: return AgentAttentionKind.blocker.iconName
        case .idle, .running, .waiting, .failed, .completed, .question: return nil
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
                if agent.notificationsMuted {
                    Image(.notification)
                } else {
                    Image(systemName: agent.notificationsMuteToggleSymbol)
                }
            }
        }
    }
}

struct AgentRowView: View {
    let agent: AgentSession
    let colorScheme: ColorScheme
    var indented: Bool = false
    var isSelected = false
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var avatarState: AgentAvatarState { AgentAvatarState.state(for: agent) }

    /// Muting hides attention cues but preserves the running dot.
    private var cornerIcon: String? {
        agent.notificationsMuted ? nil : avatarState.cornerIcon
    }

    var body: some View {
        HStack(alignment: .top, spacing: WorkspaceDetailStyle.avatarSpacing) {
            avatar
            agentDetails
        }
        .frame(minHeight: Constants.Accessibility.minimumTapTarget, alignment: .top)
        .frame(maxWidth: .infinity, alignment: .leading)
        .workspaceSidebarSelection(isSelected)
        .padding(.leading, indented ? WorkspaceDetailStyle.noteIndentation : 0)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    private var avatar: some View {
        ZStack(alignment: .topTrailing) {
            AgentAvatarView(
                agentId: agent.id,
                size: WorkspaceDetailStyle.avatarSize,
                specialist: agent.specialist,
                isActive: avatarState == .running,
                state: avatarState,
                workspaceStyle: true
            )
            if avatarState == .running {
                Circle()
                    .fill(.green)
                    .frame(
                        width: Constants.AgentRow.activeDotSize,
                        height: Constants.AgentRow.activeDotSize
                    )
                    .offset(x: Constants.AgentRow.activeDotOffset, y: -Constants.AgentRow.activeDotOffset)
            } else if let icon = cornerIcon {
                Image(icon)
                    .resizable()
                    .scaledToFit()
                    .frame(width: Constants.AgentRow.attentionIconSize, height: Constants.AgentRow.attentionIconSize)
                    .foregroundStyle(avatarState.cornerColor)
                    .offset(x: Constants.AgentRow.attentionIconOffset, y: -Constants.AgentRow.attentionIconOffset)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(avatarState.accessibilityLabel)
    }

    private var agentDetails: some View {
        VStack(alignment: .leading, spacing: WorkspaceDetailStyle.noteTitleSpacing) {
            titleAndTimestamp
            agentStatusDescription
        }
    }

    @ViewBuilder
    private var agentStatusDescription: some View {
        if avatarState == .question {
            Text(avatarState.accessibilityLabel)
                .interFont(Constants.Typography.bodyS)
                .foregroundStyle(avatarState.cornerColor)
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
        } else if avatarState != .running, let attention = agent.pendingAttentionRequest {
            Text(attention.reason.map { "\(attention.kind.label) — \($0)" } ?? attention.kind.label)
                .interFont(Constants.Typography.bodyS)
                .foregroundStyle(attention.kind.color)
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
        } else if let message = agent.displayMessage {
            Text(Self.previewText(message))
                .interFont(Constants.Typography.bodyS)
                .tracking(WorkspaceDetailStyle.bodyTracking)
                .foregroundStyle(WorkspaceDetailStyle.secondary(
                    for: colorScheme,
                    contrast: colorSchemeContrast
                ))
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
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
                .interFont(Constants.Typography.bodyM)
                .tracking(WorkspaceDetailStyle.rowTitleTracking)
                .foregroundStyle(WorkspaceDetailStyle.foreground(for: colorScheme))
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
                .foregroundStyle(WorkspaceDetailStyle.secondary(
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
                .foregroundStyle(WorkspaceDetailStyle.secondary(
                    for: colorScheme,
                    contrast: colorSchemeContrast
                ))
                .fixedSize()
        }
    }

    private func relativeDate(from isoString: String) -> String {
        guard let date = ISO8601DateFormatter.lenientDate(from: isoString) else { return isoString }
        return date.relativeFormatted
    }
}

// MARK: - Collapsible Headers

struct DelegatedAgentsRow: View {
    let agents: [AgentSession]
    var totalCount: Int?
    var runningCount: Int?
    let isExpanded: Bool
    let colorScheme: ColorScheme
    let onToggle: () -> Void
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast

    var body: some View {
        Button(action: onToggle) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: WorkspaceDetailStyle.stackSpacing) {
                    avatarStack
                    summaryLabel
                }
                VStack(alignment: .leading, spacing: WorkspaceDetailStyle.noteTitleSpacing) {
                    avatarStack
                    summaryLabel
                }
            }
            .frame(maxWidth: .infinity, minHeight: Constants.Accessibility.minimumTapTarget, alignment: .leading)
            .padding(.leading, WorkspaceDetailStyle.avatarSize + WorkspaceDetailStyle.avatarSpacing)
            .contentShape(Rectangle())
        }
        .buttonStyle(IntentContentButtonStyle())
        .accessibilityLabel(summaryTitle)
        .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
        .visionListRowHitTarget()
    }

    private var summaryLabel: some View {
        Text("+\(totalCount ?? agents.count) delegated" + ((runningCount ?? 0) > 0 ? " · \(runningCount ?? 0) running" : ""))
            .interFont(Constants.Typography.subtextXXS)
            .foregroundStyle(WorkspaceDetailStyle.secondary(for: colorScheme, contrast: colorSchemeContrast))
            .fixedSize(horizontal: false, vertical: true)
    }

    private var avatarStack: some View {
        AgentGroupAvatarStack(agents: agents, totalCount: totalCount)
    }

    private var summaryTitle: String {
        let runningCount = self.runningCount ?? agents.count { AgentAvatarState.state(for: $0) == .running }
        return AgentGroupSummary.delegatedRunningTitle(
            runningCount: runningCount,
            totalCount: totalCount ?? agents.count
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
    @ScaledMetric(relativeTo: .caption) private var chevronSize = Constants.Typography.subtextXXS.size
    let agents: [AgentSession]
    var totalCount: Int?
    var title = "background agents"
    var runningCount = 0
    let isExpanded: Bool
    let colorScheme: ColorScheme
    let onToggle: () -> Void

    var body: some View {
        Button(action: onToggle) {
            HStack(spacing: Constants.AgentRow.headerSpacing) {
                AgentGroupAvatarStack(agents: agents, totalCount: totalCount)

                Text("\(totalCount ?? agents.count) \(title)" + (runningCount > 0 ? " · \(runningCount) running" : ""))
                    .interFont(Constants.Typography.subtextXXS)
                    .foregroundStyle(Theme.mutedForeground(for: colorScheme))

                Spacer()

                Image(isExpanded ? .chevronDown : .chevronRight)
                    .resizable()
                    .scaledToFit()
                    .frame(width: chevronSize, height: chevronSize)
                    .foregroundStyle(Theme.mutedForeground(for: colorScheme))
                    .accessibilityHidden(true)
            }
            .padding(.vertical, Constants.AgentRow.backgroundVerticalPadding)
        }
        .buttonStyle(IntentContentButtonStyle())
        .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
        .visionListRowHitTarget()
    }
}
