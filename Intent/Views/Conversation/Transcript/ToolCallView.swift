import SwiftUI

struct ToolCallView: View {
    let block: ContentBlock
    let toolResult: ContentBlock?
    /// True while a slim-truncated body (input or output) is being hydrated
    /// via agent.getMessageBlock (PROTOCOL §5.5).
    var isHydrating: Bool = false
    /// Invalidates the transcript's settled row height before disclosure.
    var onLayoutChange: (() -> Void)?
    /// Fetch the full bodies of this row's slim-truncated blocks; absent →
    /// no hydration (the bounded preview stays).
    var onHydrate: (() -> Void)?
    @Environment(\.colorScheme) var colorScheme
    @State private var isExpanded = false

    private typealias Layout = Constants.Conversation.ToolCall

    private var toolName: String {
        block.resolvedName ?? "tool"
    }

    /// A slim-served row: the input and/or output is a bounded preview
    /// (PROTOCOL §5.5); expanding triggers the on-demand full fetch.
    private var isTruncated: Bool {
        block.inputTruncation.isTruncated || toolResult?.outputTruncation.isTruncated == true
    }

    private var hasError: Bool {
        toolResult?.resolvedErrorOutcome.isFailure == true
    }

    // MARK: - Tool Classification

    private var classified: ToolClassifier.ToolDisplay {
        ToolClassifier.classify(name: toolName, input: block.input)
    }

    // MARK: - Border Color (status indicator)

    private var borderColor: Color {
        if toolResult == nil { return Color.blue }
        return hasError ? Theme.destructive(for: colorScheme) : Color.green.opacity(Layout.successBorderOpacity)
    }

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerButton
            if isExpanded {
                expandedContent
            }
        }
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(borderColor)
                .frame(width: Layout.statusBorderWidth)
        }
    }

    private var headerButton: some View {
        Button {
            onLayoutChange?()
            withAnimation(.easeInOut(duration: Constants.Conversation.ToolCall.expansionAnimationDuration)) {
                isExpanded.toggle()
            }
            if isExpanded, isTruncated {
                onHydrate?()
            }
        } label: {
            HStack(spacing: Layout.headerSpacing) {
                Text(classified.icon)
                    .font(.caption2)
                Text(classified.verb)
                    .interFont(Constants.Typography.subtextXXS)
                    .foregroundStyle(Theme.mutedForeground(for: colorScheme))
                if let subject = classified.subject {
                    Text(subject)
                        .interFont(Constants.Typography.subtextXXS)
                        .foregroundStyle(Theme.foreground(for: colorScheme))
                        .lineLimit(1)
                }
                if let path = classified.path {
                    Text(path)
                        .interFont(Constants.Typography.subtextXXS)
                        .foregroundStyle(Theme.mutedForeground(for: colorScheme).opacity(Layout.pathOpacity))
                        .lineLimit(1)
                }
                Spacer()
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: Layout.disclosureFontSize))
                    .foregroundStyle(Theme.mutedForeground(for: colorScheme).opacity(Layout.disclosureOpacity))
                    .accessibilityHidden(true)
            }
            .padding(.leading, Layout.headerLeadingPadding)
            .padding(.vertical, Layout.headerVerticalPadding)
            // Text-bearing assistant rows carry the copy overlay
            // (MessageCopyContextMenu); without a pass-through marker it
            // claims the header tap and the row never expands (ios#344).
            .copyContextMenuPassthrough()
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var expandedContent: some View {
        VStack(alignment: .leading, spacing: Layout.expandedContentSpacing) {
            if isTruncated {
                hydrationStatus
            }
            if !block.input.isEmpty {
                inputSection
            }
            if let result = toolResult {
                resultSection(result)
            }
        }
        .padding(.horizontal, Layout.expandedHorizontalPadding)
        .padding(.bottom, Layout.expandedBottomPadding)
    }

    private var hydrationStatus: some View {
        Button { onHydrate?() } label: {
            HStack(spacing: Layout.hydrationStatusSpacing) {
                if isHydrating {
                    ProgressView()
                        .controlSize(.mini)
                    Text("Loading full content…")
                        .interFont(Constants.Typography.subtextXXS)
                } else {
                    Image(systemName: "arrow.down.circle")
                        .font(.caption2)
                        .accessibilityHidden(true)
                    Text(onHydrate != nil ? "Preview — tap to load full content" : "Preview")
                        .interFont(Constants.Typography.subtextXXS)
                }
            }
            .font(.caption2)
            .foregroundStyle(Theme.mutedForeground(for: colorScheme))
            .copyContextMenuPassthrough()
        }
        .buttonStyle(.plain)
        .disabled(isHydrating || onHydrate == nil)
    }

    private var inputSection: some View {
        Group {
            Text("Input")
                .interFont(Constants.Typography.subtextXXS.withFace(.semibold))
                .foregroundStyle(Theme.mutedForeground(for: colorScheme))
            ScrollView(.horizontal) {
                Text(formatJSON(block.input))
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(Theme.foreground(for: colorScheme))
            }
            .scrollIndicators(.hidden)
        }
    }

    @ViewBuilder
    private func resultSection(_ result: ContentBlock) -> some View {
        Divider()
        Text(hasError ? "Error" : "Result")
            .interFont(Constants.Typography.subtextXXS.withFace(.semibold))
            .foregroundStyle(hasError
                ? Theme.destructive(for: colorScheme)
                : Theme.mutedForeground(for: colorScheme))
        if let output = result.output {
            ScrollView {
                Text(String(describing: output.value).prefix(Constants.Conversation.ToolCall.outputCharacterLimit))
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(Theme.foreground(for: colorScheme))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: Constants.Conversation.ToolCall.outputMaximumHeight)
        }
    }

    private func formatJSON(_ dict: [String: AnyCodable]) -> String {
        guard let data = try? JSONSerialization.data(
            withJSONObject: dict.mapValues { $0.value },
            options: [.prettyPrinted, .sortedKeys]
        ), let str = String(data: data, encoding: .utf8) else {
            return String(describing: dict)
        }
        return str
    }
}
