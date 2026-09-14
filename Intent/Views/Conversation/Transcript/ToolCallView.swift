import SwiftUI

struct ToolCallView: View {
    let block: ContentBlock
    let toolResult: ContentBlock?
    /// True while a slim-truncated body (input or output) is being hydrated
    /// via agent.getMessageBlock (PROTOCOL §5.5).
    var isHydrating: Bool = false
    /// Fetch the full bodies of this row's slim-truncated blocks; absent →
    /// no hydration (the bounded preview stays).
    var onHydrate: (() -> Void)?
    @Environment(\.colorScheme) var colorScheme
    @State private var isExpanded = false

    private var toolName: String {
        block.resolvedName ?? "tool"
    }

    /// A slim-served row: the input and/or output is a bounded preview
    /// (PROTOCOL §5.5); expanding triggers the on-demand full fetch.
    private var isTruncated: Bool {
        block.inputTruncated == true || toolResult?.outputTruncated == true
    }

    private var hasError: Bool {
        toolResult?.resolvedIsError == true
    }

    // MARK: - Tool Classification

    private var classified: ToolClassifier.ToolDisplay {
        ToolClassifier.classify(name: toolName, input: block.input)
    }

    // MARK: - Border Color (status indicator)

    private var borderColor: Color {
        if toolResult == nil { return Color.blue }
        return hasError ? Theme.destructive(for: colorScheme) : Color.green.opacity(0.5)
    }

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Compact single-line header
            Button {
                withAnimation(.easeInOut(duration: Constants.Conversation.ToolCall.expansionAnimationDuration)) {
                    isExpanded.toggle()
                }
                // Expanding a slim-truncated row triggers the on-demand full
                // fetch (no-op for under-budget rows).
                if isExpanded, isTruncated {
                    onHydrate?()
                }
            } label: {
                HStack(spacing: 4) {
                    Text(classified.icon)
                        .font(.caption2)
                    Text(classified.verb)
                        .font(.caption)
                        .foregroundStyle(Theme.mutedForeground(for: colorScheme))
                    if let subject = classified.subject {
                        Text(subject)
                            .font(.caption)
                            .foregroundStyle(Theme.foreground(for: colorScheme))
                            .lineLimit(1)
                    }
                    if let path = classified.path {
                        Text(path)
                            .font(.caption2)
                            .foregroundStyle(Theme.mutedForeground(for: colorScheme).opacity(0.6))
                            .lineLimit(1)
                    }
                    Spacer()
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 8))
                        .foregroundStyle(Theme.mutedForeground(for: colorScheme).opacity(0.4))
                        .accessibilityHidden(true)
                }
                .padding(.leading, 8)
                .padding(.vertical, 3)
            }
            .buttonStyle(.plain)

            if isExpanded {
                expandedContent
            }
        }
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(borderColor)
                .frame(width: 2)
        }
    }

    @ViewBuilder
    private var expandedContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            // While the full block is hydrating (PROTOCOL §5.5), the slim
            // preview below stays visible with a loading hint on top; once
            // the full block merges in, the truncation flags disappear and
            // this hint retires. A tap retries a failed fetch.
            if isTruncated {
                Button { onHydrate?() } label: {
                    HStack(spacing: 4) {
                        if isHydrating {
                            ProgressView()
                                .controlSize(.mini)
                            Text("Loading full content…")
                        } else {
                            Image(systemName: "arrow.down.circle")
                                .font(.caption2)
                                .accessibilityHidden(true)
                            Text(onHydrate != nil ? "Preview — tap to load full content" : "Preview")
                        }
                    }
                    .font(.caption2)
                    .foregroundStyle(Theme.mutedForeground(for: colorScheme))
                }
                .buttonStyle(.plain)
                .disabled(isHydrating || onHydrate == nil)
            }
            if let input = block.input, !input.isEmpty {
                Text("Input")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.mutedForeground(for: colorScheme))
                ScrollView(.horizontal) {
                    Text(formatJSON(input))
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(Theme.foreground(for: colorScheme))
                }
                .scrollIndicators(.hidden)
            }
            if let result = toolResult {
                Divider()
                Text(hasError ? "Error" : "Result")
                    .font(.caption.weight(.semibold))
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
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 10)
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
