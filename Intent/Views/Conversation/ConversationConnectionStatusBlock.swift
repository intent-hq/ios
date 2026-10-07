import SwiftUI

/// Inline progress shared by conversation loading surfaces. The caller owns
/// the start date so stage changes and manual retries keep one elapsed clock.
struct ConversationConnectionStatusBlock: View {
    let stage: ConversationLiveTranscript.LoadingStage
    let startedAt: Date
    let onRetry: () async -> Void
    @Environment(\.colorScheme) private var colorScheme

    private typealias Layout = Constants.Conversation.Column.Loading

    private var stageText: Text {
        switch stage {
        case .idle: Text("Loading conversation")
        case .connecting: Text("Connecting to the daemon")
        case .requesting: Text("Asking the daemon")
        case .receiving: Text("Receiving messages")
        case .retrying(let attempt): Text("Retrying (attempt \(attempt))")
        }
    }

    private var currentStep: Int {
        switch stage {
        case .idle, .connecting: 0
        case .requesting, .retrying: 1
        case .receiving: 2
        }
    }

    var body: some View {
        TimelineView(.periodic(from: startedAt, by: Layout.timelineInterval)) { context in
            let seconds = max(0, context.date.timeIntervalSince(startedAt))
            let elapsed = Duration.seconds(seconds).formatted(.time(pattern: .minuteSecond))
            VStack(alignment: .leading, spacing: Layout.rowSpacing) {
                HStack(alignment: .top, spacing: Layout.contentSpacing) {
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: Layout.iconDimension, height: Layout.iconDimension)
                        .accessibilityHidden(true)
                    stageText
                        .fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text("\(stageText), elapsed: \(elapsed)"))
                .accessibilityIdentifier("conversation.connectionStatus")

                if seconds >= Layout.slowThreshold {
                    ConversationConnectionDelayDetails(elapsed: elapsed, currentStep: currentStep, onRetry: onRetry)
                }
            }
            .interFont(Constants.Typography.bodyS)
            .foregroundStyle(Theme.mutedForeground(for: colorScheme))
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct ConversationConnectionDelayDetails: View {
    let elapsed: String
    let currentStep: Int
    let onRetry: () async -> Void
    @State private var isExpanded = false
    @State private var retryInProgress = false

    private typealias Layout = Constants.Conversation.Column.Loading

    var body: some View {
        VStack(alignment: .leading, spacing: Layout.rowSpacing) {
            Button {
                isExpanded.toggle()
            } label: {
                ConversationConnectionDelayLabel(elapsed: elapsed, isExpanded: isExpanded)
            }
            .buttonStyle(IntentContentButtonStyle())
            .accessibilityValue(isExpanded ? Text("Expanded") : Text("Collapsed"))
            .accessibilityHint("Show or hide connection steps")
            .accessibilityIdentifier("conversation.connectionDetails")

            if isExpanded {
                VStack(alignment: .leading, spacing: Layout.contentSpacing) {
                    ConversationConnectionStep(title: "Connecting to the daemon", index: 0, currentStep: currentStep)
                    ConversationConnectionStep(title: "Asking the daemon", index: 1, currentStep: currentStep)
                    ConversationConnectionStep(title: "Receiving messages", index: 2, currentStep: currentStep)
                }
            }

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

private struct ConversationConnectionDelayLabel: View {
    let elapsed: String
    let isExpanded: Bool

    private typealias Layout = Constants.Conversation.Column.Loading

    var body: some View {
        HStack(alignment: .top, spacing: Layout.contentSpacing) {
            Image(systemName: "exclamationmark.circle")
                .frame(width: Layout.iconDimension, height: Layout.iconDimension)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Layout.detailSpacing) {
                Text("Elapsed: \(elapsed)").monospacedDigit()
                Text("Taking longer than usual")
            }
            .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Image(systemName: isExpanded ? "chevron.down" : "chevron.forward")
                .accessibilityHidden(true)
        }
        .frame(maxWidth: .infinity, minHeight: Layout.minimumTapHeight, alignment: .leading)
        .contentShape(Rectangle())
    }
}

private struct ConversationConnectionStep: View {
    let title: LocalizedStringKey
    let index: Int
    let currentStep: Int

    private var state: Text {
        if index < currentStep { Text("Done") } else if index == currentStep { Text("Current") } else { Text("Pending") }
    }

    var body: some View {
        HStack(spacing: Constants.Conversation.Column.Loading.contentSpacing) {
            Image(systemName: index < currentStep ? "checkmark.circle.fill" : index == currentStep ? "circle.inset.filled" : "circle")
                .frame(width: Constants.Conversation.Column.Loading.iconDimension)
                .accessibilityHidden(true)
            Text(title)
        }
        .interFont(Constants.Typography.bodyXS)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("\(Text(title)), \(state)"))
    }
}
