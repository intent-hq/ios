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

    /// Max characters of a hook name shown on a chip (mirrors the FE's
    /// visual max-width truncation).
    private static let nameMaxLength = 24
    private static let repeatIconFontSize: CGFloat = 8
    private static let chipTopPadding: CGFloat = 4
    private static let chipBottomPadding: CGFloat = 6
    private static let chipBackgroundOpacity = 0.3
    private static let timeBarInset: CGFloat = 3

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
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundStyle(Theme.mutedForeground(for: colorScheme))

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
                .font(.caption2)
                .lineLimit(1)
            if hook.perpetual {
                Image(systemName: "repeat")
                    .font(.system(size: Self.repeatIconFontSize))
                    .accessibilityLabel("Repeating hook")
            }
            if hook.state == .running {
                ProgressView()
                    .controlSize(.mini)
            }
        }
        .foregroundStyle(Theme.mutedForeground(for: colorScheme))
        .padding(.horizontal, Constants.Conversation.StatusStrip.chipHorizontalPadding)
        .padding(.top, Self.chipTopPadding)
        .padding(.bottom, Self.chipBottomPadding)
        .background(Theme.muted(for: colorScheme).opacity(Self.chipBackgroundOpacity))
        .overlay(alignment: .bottom) {
            if hook.state == .scheduled, let nextRunAt = hook.nextRunAt {
                HookTimeBar(
                    nextRunAt: nextRunAt,
                    delayMs: hook.delayMs,
                    color: Theme.mutedForeground(for: colorScheme).opacity(0.5)
                )
                .id(nextRunAt)
                .padding(.horizontal, Self.timeBarInset)
                .padding(.bottom, Self.timeBarInset)
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
        if name.count <= Self.nameMaxLength { return name }
        return name.prefix(Self.nameMaxLength) + "…"
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

/// Thin shrinking time-to-next-run bar: a single linear animation from the
/// not-yet-elapsed fraction of the `delayMs` cycle down to zero (mirrors the
/// FE's pure-CSS bar — no timers, no daemon polling). The parent re-creates
/// it via `.id(nextRunAt)` so each new cycle restarts the animation.
private struct HookTimeBar: View {
    let nextRunAt: String
    let delayMs: Int
    let color: Color

    @State private var fraction: CGFloat = 1

    private static let millisecondsPerSecond = 1000.0

    var body: some View {
        Rectangle()
            .fill(color)
            .frame(height: 1)
            .scaleEffect(x: fraction, y: 1, anchor: .leading)
            .onAppear(perform: start)
    }

    private func start() {
        guard delayMs > 0,
              let next = ISO8601DateFormatter.lenientDate(from: nextRunAt) else {
            fraction = 0
            return
        }
        let total = Double(delayMs) / Self.millisecondsPerSecond
        let remaining = max(0, min(total, next.timeIntervalSinceNow))
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { fraction = CGFloat(remaining / total) }
        withAnimation(.linear(duration: remaining)) { fraction = 0 }
    }
}
