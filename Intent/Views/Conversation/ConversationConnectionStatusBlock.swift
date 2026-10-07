import SwiftUI

/// Inline progress shared by conversation loading surfaces. The caller owns
/// the start date so stage changes and manual retries keep one elapsed clock.
struct ConversationConnectionStatusBlock<Phase: Equatable>: View {
    let phase: Phase
    let message: LocalizedStringResource
    let startedAt: Date
    let onRetry: () async -> Void
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var timing: ConversationConnectionStatusTiming<Phase>

    private typealias Layout = Constants.Conversation.Column.Loading

    init(phase: Phase, message: LocalizedStringResource, startedAt: Date, onRetry: @escaping () async -> Void) {
        self.phase = phase
        self.message = message
        self.startedAt = startedAt
        self.onRetry = onRetry
        _timing = State(initialValue: ConversationConnectionStatusTiming(phase: phase, startedAt: startedAt))
    }

    var body: some View {
        TimelineView(.periodic(from: startedAt, by: Layout.timelineInterval)) { context in
            let elapsed = timing.elapsed(at: context.date).formatted(.time(pattern: .minuteSecond))
            let isDelayed = timing.isDelayed(phase: phase, at: context.date)
            VStack(alignment: .leading, spacing: Layout.rowSpacing) {
                HStack(alignment: .top, spacing: Layout.contentSpacing) {
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: Layout.iconDimension, height: Layout.iconDimension)
                        .accessibilityHidden(true)
                    Text(message)
                        .fixedSize(horizontal: false, vertical: true)
                        .contentTransition(.opacity)
                        .animation(reduceMotion ? nil : .easeInOut(duration: Layout.fadeDuration), value: phase)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(isDelayed
                    ? Text("\(Text(message)), elapsed: \(elapsed), Taking longer than usual") : Text(message))
                .accessibilityIdentifier("conversation.connectionStatus")

                if isDelayed {
                    ConversationConnectionDelayDetails(elapsed: elapsed, onRetry: onRetry)
                }
            }
            .interFont(Constants.Typography.bodyS)
            .foregroundStyle(Theme.mutedForeground(for: colorScheme))
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onChange(of: phase) { _, newPhase in
            timing.update(phase: newPhase, at: Date())
        }
    }
}

private struct ConversationConnectionDelayDetails: View {
    let elapsed: String
    let onRetry: () async -> Void
    @State private var retryInProgress = false

    private typealias Layout = Constants.Conversation.Column.Loading

    var body: some View {
        VStack(alignment: .leading, spacing: Layout.rowSpacing) {
            Text("Elapsed: \(elapsed) · Taking longer than usual")
                .monospacedDigit()
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("conversation.connectionDetails")
                .accessibilityHidden(true)

            Button("Retry Now") {
                retryInProgress = true
                Task {
                    await onRetry()
                    retryInProgress = false
                }
            }
            .buttonStyle(IntentButtonStyle())
            .disabled(retryInProgress)
            .padding(.top, Layout.retryTopPadding)
            .accessibilityIdentifier("conversation.retryNow")
        }
    }
}
