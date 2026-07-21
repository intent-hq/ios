import SwiftUI

struct ToolCallView: View {
    let block: ContentBlock
    let toolResult: ContentBlock?
    @Environment(\.colorScheme) var colorScheme
    @State private var isExpanded = false

    private var toolName: String {
        block.resolvedName ?? "tool"
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
            Button { withAnimation(.easeInOut(duration: 0.2)) { isExpanded.toggle() } } label: {
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
            if let input = block.input, !input.isEmpty {
                Text("Input")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.mutedForeground(for: colorScheme))
                ScrollView(.horizontal, showsIndicators: false) {
                    Text(formatJSON(input))
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(Theme.foreground(for: colorScheme))
                }
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
                        Text(String(describing: output.value).prefix(2000))
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(Theme.foreground(for: colorScheme))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 200)
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

