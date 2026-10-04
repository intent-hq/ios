import SwiftUI

/// Faint chip row above the composer surfacing the active agent's background
/// hooks (PROTOCOL §5.40) — the iOS counterpart of cloudlands-fe's
/// `BackgroundHooksRow`. One chip per `scheduled`/`running` hook: a spinner
/// while a run is in flight, a thin shrinking time-to-next-run bar while
/// scheduled (derived from `nextRunAt` − now over `delayMs`; a local
/// animation, no daemon polling). Perpetual hooks carry a small repeat glyph.
/// Tapping a chip opens a menu whose header shows name/state, next run,
/// TTL expiry and last error, with Run now / Cancel hook actions. The parent
/// hides the row entirely when the agent has no active hooks. No code preview
/// on iOS (per spec decision).
struct BackgroundHooksRow: View {
    let viewModel: ConversationViewModel
    private let hookStore: BackgroundHookStore
    @Environment(\.colorScheme) var colorScheme

    private typealias Layout = Constants.Conversation.StatusStrip.BackgroundHooks

    init(viewModel: ConversationViewModel, hookStore: BackgroundHookStore) {
        self.viewModel = viewModel
        self.hookStore = hookStore
    }

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: Constants.Conversation.StatusStrip.contentSpacing) {
                Image(systemName: "bolt.fill")
                    .font(.caption2)
                    .foregroundStyle(Theme.mutedForeground(for: colorScheme))
                    .accessibilityHidden(true)
                Text("Running hooks")
                    .interFont(Constants.Typography.subtextXXS.withFace(.medium))
                    .foregroundStyle(Theme.mutedForeground(for: colorScheme))

                if hookStore.error != nil {
                    Button {
                        Task { await hookStore.refetch() }
                    } label: {
                        Label("Status unavailable · Retry", systemImage: "exclamationmark.triangle")
                    }
                    .font(.caption2)
                    .accessibilityLabel("Hooks may be out of date. Retry refresh")
                }

                ForEach(hookStore.activeHooks.filter { $0.agentId == viewModel.agentId }) { hook in
                    hookChip(hook)
                }
            }
            .padding(.horizontal, Constants.Conversation.StatusStrip.horizontalPadding)
            .padding(.vertical, Constants.Conversation.StatusStrip.verticalPadding)
        }
        .scrollIndicators(.hidden)
        .background(Theme.card(for: colorScheme).opacity(Constants.Conversation.StatusStrip.backgroundOpacity))
        .opacity(Constants.Conversation.StatusStrip.contentOpacity)
    }

    // MARK: - Chip

    @ViewBuilder
    private func hookChip(_ hook: BackgroundHook) -> some View {
        Menu {
            // Detail header: name/state plus timing + error lines (mirrors
            // the FE hover card). Positional IDs: lines are display strings
            // with no inherent identity.
            ForEach(Array(Self.detailLines(hook).enumerated()), id: \.offset) { _, line in
                Text(line)
            }
            Divider()
            Button {
                Task { await hookStore.runNow(hookId: hook.hookId) }
            } label: {
                Label("Run now", systemImage: "play")
            }
            .disabled(hook.state == .running)
            Button(role: .destructive) {
                Task { await hookStore.cancel(hookId: hook.hookId) }
            } label: {
                Label("Cancel hook", systemImage: "xmark")
            }
        } label: {
            chipLabel(hook)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func chipLabel(_ hook: BackgroundHook) -> some View {
        HStack(spacing: Constants.Conversation.StatusStrip.chipSpacing) {
            Text(truncatedName(hook.name))
                .interFont(Constants.Typography.subtextXXS)
                .lineLimit(1)
            if hook.perpetual {
                Image(systemName: "repeat")
                    .font(.system(size: Layout.repeatIconFontSize))
                    .accessibilityLabel("Repeating hook")
            }
            if hook.state == .running {
                ProgressView()
                    .controlSize(.mini)
            }
        }
        .foregroundStyle(Theme.mutedForeground(for: colorScheme))
        .padding(.horizontal, Constants.Conversation.StatusStrip.chipHorizontalPadding)
        .padding(.top, Layout.chipTopPadding)
        .padding(.bottom, Layout.chipBottomPadding)
        .background(Theme.muted(for: colorScheme).opacity(Layout.chipBackgroundOpacity))
        .overlay(alignment: .bottom) {
            if hook.state == .scheduled, let nextRunAt = hook.nextRunAt {
                HookTimeBar(
                    nextRunAt: nextRunAt,
                    delayMs: hook.delayMs,
                    color: Theme.mutedForeground(for: colorScheme).opacity(Layout.timeBarOpacity)
                )
                .frame(height: Layout.timeBarHeight)
                .id(nextRunAt)
                .padding(.horizontal, Layout.timeBarInset)
                .padding(.bottom, Layout.timeBarInset)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: Constants.Conversation.StatusStrip.chipCornerRadius))
        .overlay(
            RoundedRectangle(cornerRadius: Constants.Conversation.StatusStrip.chipCornerRadius)
                .strokeBorder(
                    Theme.border(for: colorScheme).opacity(Constants.Conversation.StatusStrip.chipBorderOpacity),
                    lineWidth: Constants.Conversation.StatusStrip.chipBorderWidth
                )
        )
    }

    private func truncatedName(_ name: String) -> String {
        if name.count <= Layout.nameMaxLength { return name }
        return name.prefix(Layout.nameMaxLength) + "…"
    }

    // MARK: - Display helpers (pure, unit-tested)

    /// Menu-header detail lines: name/state, "next run in …" / "expires
    /// in …" relative durations (mirroring the FE hover card's
    /// nextRunIn/expiresIn helpers; computed against `now` when the menu
    /// renders), and the last run error when present. Timing lines are
    /// dropped when the underlying timestamp is absent or unparseable.
    static func detailLines(_ hook: BackgroundHook, now: Date = Date()) -> [String] {
        var lines = ["\(hook.name) — \(stateLabel(hook))"]
        if let next = ISO8601DateFormatter.lenientDate(from: hook.nextRunAt) {
            lines.append("Next run: in \(DurationFormat.compact(next.timeIntervalSince(now)))")
        }
        if let expires = ISO8601DateFormatter.lenientDate(from: hook.expiresAt) {
            lines.append("TTL: expires in \(DurationFormat.compact(expires.timeIntervalSince(now)))")
        }
        if let lastError = hook.lastError, !lastError.isEmpty {
            lines.append("Last error: \(lastError)")
        }
        return lines
    }

    static func stateLabel(_ hook: BackgroundHook) -> String {
        hook.state == .running ? "Running" : "Scheduled"
    }
}
