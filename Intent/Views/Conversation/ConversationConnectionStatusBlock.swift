import SwiftUI

/// Inline progress shared by conversation loading surfaces. The caller owns
/// the start date so stage changes and manual retries keep one elapsed clock.
struct ConversationConnectionStatusBlock<Phase: Equatable>: View {
    let phase: Phase
    let message: LocalizedStringResource
    let currentStep: ConversationConnectionStep
    let startedAt: Date
    let onRetry: () async -> Void
    @Environment(\.colorScheme) private var colorScheme
    @State private var timing: ConversationConnectionStatusTiming<Phase>

    private typealias Layout = Constants.Conversation.Column.Loading

    init(
        phase: Phase, message: LocalizedStringResource, currentStep: ConversationConnectionStep,
        startedAt: Date, onRetry: @escaping () async -> Void
    ) {
        self.phase = phase
        self.message = message
        self.currentStep = currentStep
        self.startedAt = startedAt
        self.onRetry = onRetry
        _timing = State(initialValue: ConversationConnectionStatusTiming(phase: phase, startedAt: startedAt))
    }

    var body: some View {
        TimelineView(.periodic(from: startedAt, by: Layout.timelineInterval)) { context in
            let elapsed = timing.elapsed(at: context.date).formatted(.time(pattern: .minuteSecond))
            let isDelayed = timing.isDelayed(phase: phase, at: context.date)
            VStack(alignment: .leading, spacing: Layout.rowSpacing) {
                ConversationConnectionStatusHeader(
                    phase: phase, message: message, elapsed: isDelayed ? elapsed : nil
                )

                VStack(alignment: .leading, spacing: Layout.contentSpacing) {
                    ForEach(ConversationConnectionStep.allCases, id: \.self) { step in
                        ConversationConnectionStepRow(step: step, currentStep: currentStep)
                    }
                }

                if isDelayed {
                    ConversationConnectionRetryButton(onRetry: onRetry)
                }
            }
            .interFont(Constants.Typography.bodyS)
            .foregroundStyle(Theme.mutedForeground(for: colorScheme))
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("conversation.connectionStatusBlock")
        }
        .onChange(of: phase) { _, newPhase in
            timing.update(phase: newPhase, at: Date())
        }
    }
}

private struct ConversationConnectionStatusHeader<Phase: Equatable>: View {
    let phase: Phase
    let message: LocalizedStringResource
    let elapsed: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private typealias Layout = Constants.Conversation.Column.Loading

    var body: some View {
        HStack(alignment: .top, spacing: Layout.contentSpacing) {
            ProgressView()
                .controlSize(.small)
                .frame(width: Layout.iconDimension, height: Layout.iconDimension)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Layout.detailSpacing) {
                Text(message)
                    .contentTransition(.opacity)
                    .animation(reduceMotion ? nil : .easeInOut(duration: Layout.fadeDuration), value: phase)
                if let elapsed {
                    Text("Elapsed: \(elapsed) · Taking longer than usual")
                        .interFont(Constants.Typography.bodyXS)
                        .monospacedDigit()
                }
            }
            .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(elapsed.map { Text("\(Text(message)), elapsed: \($0), Taking longer than usual") } ?? Text(message))
        .accessibilityIdentifier("conversation.connectionStatus")
    }
}

private struct ConversationConnectionStepRow: View {
    let step: ConversationConnectionStep
    let currentStep: ConversationConnectionStep

    private var state: Text {
        if step.rawValue < currentStep.rawValue { Text("Done") } else if step == currentStep { Text("Current") } else { Text("Pending") }
    }

    private var symbol: String {
        if step.rawValue < currentStep.rawValue { "checkmark.circle.fill" } else if step == currentStep { "circle.inset.filled" } else { "circle" }
    }

    var body: some View {
        HStack(spacing: Constants.Conversation.Column.Loading.contentSpacing) {
            Image(systemName: symbol)
                .frame(width: Constants.Conversation.Column.Loading.iconDimension)
                .accessibilityHidden(true)
            Text(step.title)
        }
        .interFont(Constants.Typography.bodyXS)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("\(Text(step.title)), \(state)"))
    }
}

private struct ConversationConnectionRetryButton: View {
    let onRetry: () async -> Void
    @State private var retryInProgress = false

    var body: some View {
        Button("Retry Now") {
            retryInProgress = true
            Task {
                await onRetry()
                retryInProgress = false
            }
        }
        .buttonStyle(IntentButtonStyle())
        .disabled(retryInProgress)
        .padding(.top, Constants.Conversation.Column.Loading.retryTopPadding)
        .accessibilityIdentifier("conversation.retryNow")
    }
}
