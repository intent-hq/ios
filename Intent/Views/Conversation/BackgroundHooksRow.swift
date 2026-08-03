import SwiftUI

/// Faint chip row above the composer surfacing the active agent's background
/// hooks (PROTOCOL §5.40) — the iOS counterpart of cloudlands-fe's
/// `BackgroundHooksRow`. One chip per `scheduled`/`running` hook: a spinner
/// while a run is in flight, a thin shrinking time-to-next-run bar while
/// scheduled (derived from `nextRunAt` − now over `delayMs`; a local
/// animation, no daemon polling). Tapping a chip opens a menu with Run now /
/// Cancel hook. The parent hides the row entirely when the agent has no
/// active hooks. No code preview on iOS (per spec decision).
struct BackgroundHooksRow: View {
    @ObservedObject var viewModel: ConversationViewModel
    @Environment(\.colorScheme) var colorScheme

    /// Max characters of a hook name shown on a chip (mirrors the FE's
    /// visual max-width truncation).
    private static let nameMaxLength = 24

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                Image(systemName: "bolt.fill")
                    .font(.caption2)
                    .foregroundStyle(Theme.mutedForeground(for: colorScheme))
                Text("Running hooks")
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundStyle(Theme.mutedForeground(for: colorScheme))

                ForEach(viewModel.activeAgentHooks) { hook in
                    hookChip(hook)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
        }
        .background(Theme.card(for: colorScheme).opacity(0.8))
        .opacity(0.85)
    }

    // MARK: - Chip

    @ViewBuilder
    private func hookChip(_ hook: BackgroundHook) -> some View {
        Menu {
            Text("\(hook.name) — \(stateLabel(hook))")
            Divider()
            Button {
                Task { await viewModel.hookStore.runNow(hookId: hook.hookId) }
            } label: {
                Label("Run now", systemImage: "play")
            }
            .disabled(hook.state == .running)
            Button(role: .destructive) {
                Task { await viewModel.hookStore.cancel(hookId: hook.hookId) }
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
        HStack(spacing: 4) {
            Text(truncatedName(hook.name))
                .font(.caption2)
                .lineLimit(1)
            if hook.state == .running {
                ProgressView()
                    .controlSize(.mini)
            }
        }
        .foregroundStyle(Theme.mutedForeground(for: colorScheme))
        .padding(.horizontal, 8)
        .padding(.top, 4)
        .padding(.bottom, 6)
        .background(Theme.muted(for: colorScheme).opacity(0.3))
        .overlay(alignment: .bottom) {
            if hook.state == .scheduled, let nextRunAt = hook.nextRunAt {
                HookTimeBar(
                    nextRunAt: nextRunAt,
                    delayMs: hook.delayMs,
                    color: Theme.mutedForeground(for: colorScheme).opacity(0.5)
                )
                .id(nextRunAt)
                .padding(.horizontal, 3)
                .padding(.bottom, 3)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(Theme.border(for: colorScheme).opacity(0.4), lineWidth: 1)
        )
    }

    private func truncatedName(_ name: String) -> String {
        if name.count <= Self.nameMaxLength { return name }
        return name.prefix(Self.nameMaxLength) + "…"
    }

    private func stateLabel(_ hook: BackgroundHook) -> String {
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

    var body: some View {
        GeometryReader { geo in
            Rectangle()
                .fill(color)
                .frame(width: geo.size.width * fraction)
        }
        .frame(height: 1)
        .onAppear(perform: start)
    }

    private func start() {
        guard delayMs > 0,
              let next = ISO8601DateFormatter.lenientDate(from: nextRunAt) else {
            fraction = 0
            return
        }
        let total = Double(delayMs) / 1000.0
        let remaining = max(0, min(total, next.timeIntervalSinceNow))
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { fraction = CGFloat(remaining / total) }
        withAnimation(.linear(duration: remaining)) { fraction = 0 }
    }
}
