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
    @Environment(\.colorSchemeContrast) private var contrast
    @State private var timing: ConversationConnectionStatusTiming<Phase>

    private typealias Layout = Constants.Conversation.Column.Loading
    private typealias Palette = Constants.Conversation.Design.Palette

    init(
        phase: Phase,
        message: LocalizedStringResource,
        currentStep: ConversationConnectionStep,
        startedAt: Date,
        onRetry: @escaping () async -> Void
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
                if timing.showsProgress(at: context.date) {
                    progressSteps(elapsed: isDelayed ? elapsed : nil)
                } else {
                    ConversationLoadingSkeleton()
                }

                if isDelayed {
                    Text("Elapsed: \(elapsed) · Taking longer than usual")
                        .interFont(Constants.Typography.bodyXS)
                        .foregroundStyle(Palette.secondaryForeground(for: colorScheme, contrast: contrast))
                        .monospacedDigit()
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityHidden(true) // Announced with the current step instead.
                    ConversationConnectionRetryButton(onRetry: onRetry)
                }
            }
            .interFont(Constants.Typography.bodyS)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("conversation.connectionStatusBlock")
        }
        .onChange(of: phase) { _, newPhase in
            timing.update(phase: newPhase, at: Date())
        }
    }

    private func progressSteps(elapsed: String?) -> some View {
        VStack(alignment: .leading, spacing: Layout.contentSpacing) {
            ForEach(ConversationConnectionStep.allCases, id: \.self) { step in
                ConversationConnectionStepRow(
                    phase: phase,
                    step: step,
                    currentStep: currentStep,
                    title: step == currentStep ? message : step.title,
                    elapsed: step == currentStep ? elapsed : nil
                )
            }
        }
    }
}

private struct ConversationLoadingSkeleton: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast
    @ScaledMetric(relativeTo: .body) private var lineHeight = Layout.lineHeight

    private enum Layout {
        static let lineHeight: CGFloat = 12
        static let lineSpacing: CGFloat = 12
        static let paragraphSpacing: CGFloat = 32
        static let cornerRadius: CGFloat = 4
        static let longLine: CGFloat = 0.9
        static let shortLine: CGFloat = 0.62
        static let firstParagraph: [CGFloat] = [longLine, 1, longLine, shortLine]
        static let secondParagraph: [CGFloat] = [1, longLine, shortLine]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Layout.paragraphSpacing) {
            paragraph(Layout.firstParagraph)
            paragraph(Layout.secondParagraph)
        }
        .padding(.vertical, Constants.Conversation.Column.Loading.contentSpacing)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Loading messages")
        .accessibilityIdentifier("conversation.loadingSkeleton")
    }

    private func paragraph(_ widths: [CGFloat]) -> some View {
        VStack(alignment: .leading, spacing: Layout.lineSpacing) {
            ForEach(widths.indices, id: \.self) { index in
                RoundedRectangle(cornerRadius: Layout.cornerRadius)
                    .fill(Constants.Conversation.Design.Palette.border(for: colorScheme, contrast: contrast))
                    .frame(height: lineHeight)
                    .scaleEffect(x: widths[index], y: 1, anchor: .leading)
            }
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
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast

    private typealias Layout = Constants.Conversation.Column.Loading
    private typealias Palette = Constants.Conversation.Design.Palette

    private var titleColor: Color {
        step == currentStep
            ? Palette.foreground(for: colorScheme)
            : Palette.secondaryForeground(for: colorScheme, contrast: contrast)
    }

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
                        .tint(Palette.foreground(for: colorScheme))
                } else if step.rawValue < currentStep.rawValue {
                    Image(.checkCircle)
                        .renderingMode(.template)
                        .resizable()
                        .scaledToFit()
                        .foregroundStyle(colorScheme == .dark ? Palette.accent : Palette.foreground(for: colorScheme))
                } else {
                    Image(.waiting)
                        .renderingMode(.template)
                        .resizable()
                        .scaledToFit()
                        .foregroundStyle(Palette.secondaryForeground(for: colorScheme, contrast: contrast))
                }
            }
            .frame(width: Layout.iconDimension, height: Layout.iconDimension)
            .accessibilityHidden(true)
            Text(title)
                .foregroundStyle(titleColor)
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

/// Terminal outcome of a bounded load (#765): no spinner, an explanation and
/// a Retry that starts a fresh cycle.
struct ConversationConnectionFailedBlock: View {
    let onRetry: () async -> Void
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast

    private typealias Palette = Constants.Conversation.Design.Palette

    var body: some View {
        VStack(alignment: .leading, spacing: Constants.Conversation.Column.Loading.rowSpacing) {
            VStack(alignment: .leading, spacing: Constants.Conversation.Column.Loading.contentSpacing) {
                Text("Couldn't load this conversation")
                    .interFont(Constants.Typography.bodyS)
                    .foregroundStyle(Palette.foreground(for: colorScheme))
                    .accessibilityAddTraits(.isHeader)
                Text("The server didn't respond. Check your connection, then try again.")
                    .interFont(Constants.Typography.bodyXS)
                    .foregroundStyle(Palette.secondaryForeground(for: colorScheme, contrast: contrast))
            }
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("conversation.loadFailed")
            ConversationConnectionRetryButton(title: "Retry", onRetry: onRetry)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("conversation.loadFailedBlock")
    }
}

private struct ConversationConnectionRetryButton: View {
    var title: LocalizedStringResource = "Retry Now"
    let onRetry: () async -> Void
    @State private var retryInProgress = false

    var body: some View {
        Button(title) {
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
