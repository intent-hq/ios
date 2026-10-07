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
                VStack(alignment: .leading, spacing: Layout.contentSpacing) {
                    ForEach(ConversationConnectionStep.allCases, id: \.self) { step in
                        ConversationConnectionStepRow(
                            phase: phase, step: step, currentStep: currentStep,
                            title: step == currentStep ? message : step.title,
                            elapsed: step == currentStep && isDelayed ? elapsed : nil
                        )
                    }
                }

                if isDelayed {
                    Text("Elapsed: \(elapsed) · Taking longer than usual")
                        .interFont(Constants.Typography.bodyXS)
                        .monospacedDigit()
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityHidden(true) // Announced with the current step instead.
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

private struct ConversationConnectionStepRow<Phase: Equatable>: View {
    let phase: Phase
    let step: ConversationConnectionStep
    let currentStep: ConversationConnectionStep
    let title: LocalizedStringResource
    let elapsed: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private typealias Layout = Constants.Conversation.Column.Loading

    private var state: Text {
        if step.rawValue < currentStep.rawValue { Text("Done") } else if step == currentStep { Text("Current") } else { Text("Pending") }
    }

    private var accessibilitySummary: Text {
        if let elapsed {
            Text("\(Text(title)), \(state), elapsed: \(elapsed), Taking longer than usual")
        } else {
            Text("\(Text(title)), \(state)")
        }
    }

    var body: some View {
        HStack(spacing: Layout.contentSpacing) {
            Group {
                if step == currentStep {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: step.rawValue < currentStep.rawValue ? "checkmark.circle.fill" : "circle")
                }
            }
            .frame(width: Layout.iconDimension, height: Layout.iconDimension)
            .accessibilityHidden(true)
            Text(title)
                .contentTransition(.opacity)
                .animation(reduceMotion ? nil : .easeInOut(duration: Layout.fadeDuration), value: phase)
                .fixedSize(horizontal: false, vertical: true)
        }
        .interFont(Constants.Typography.bodyXS)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilitySummary)
        .accessibilityIdentifier(step == currentStep ? "conversation.connectionStatus" : "conversation.connectionStep.\(step.rawValue)")
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
