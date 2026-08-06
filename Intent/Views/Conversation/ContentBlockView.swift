import SwiftUI

struct ContentBlockView: View {
    let block: ContentBlock
    let allBlocks: [ContentBlock]
    let workspaceId: String
    var onNavigateToNote: ((_ noteId: String, _ workspaceId: String, _ noteTitle: String) -> Void)? = nil
    @EnvironmentObject var coordinator: AppCoordinator
    @Environment(\.colorScheme) var colorScheme
    @State private var thinkingExpanded = false

    var body: some View {
        switch block.type {
        case .text:
            if let text = block.resolvedText {
                let cleaned = stripSuggestedPrompts(text)
                if !cleaned.isEmpty {
                    MarkdownTextView(text: cleaned, onOpenURL: { url in
                        if let targetId = NoteDetailView.parseIntentNoteLink(url) {
                            if let onNavigateToNote = onNavigateToNote {
                                onNavigateToNote(targetId, workspaceId, "Note")
                            } else {
                                coordinator.onSelectNote(targetId, workspaceId: workspaceId, noteTitle: "Note")
                            }
                            return .handled
                        }
                        return .systemAction
                    })
                }
            }

        case .code:
            CodeBlockView(
                code: block.resolvedText ?? "",
                language: block.language
            )

        case .toolUse:
            let result = findToolResult(for: block)
            ToolCallView(block: block, toolResult: result)

        case .toolResult:
            // Rendered as part of ToolCallView via pairing; skip standalone
            EmptyView()

        case .thinking:
            thinkingView

        case .image:
            imageView

        case .file:
            fileView

        case .resource:
            // Standalone resource blocks (PROTOCOL §7.1) never render in the
            // transcript; question resources are wizard-only and stripped by
            // MIME regardless of payload validity (FE parity).
            EmptyView()
        }
    }

    @ViewBuilder
    private var thinkingView: some View {
        DisclosureGroup(isExpanded: $thinkingExpanded) {
            Text(block.resolvedText ?? "")
                .font(.callout)
                .foregroundStyle(Theme.mutedForeground(for: colorScheme))
                .italic()
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 4)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "brain")
                    .font(.caption)
                Text("Thinking")
                    .font(.caption.weight(.medium))
            }
            .foregroundStyle(Theme.mutedForeground(for: colorScheme))
        }
        .tint(Theme.mutedForeground(for: colorScheme))
    }

    @ViewBuilder
    private var imageView: some View {
        if let base64 = block.data,
           let imageData = Data(base64Encoded: base64),
           let uiImage = UIImage(data: imageData) {
            Image(uiImage: uiImage)
                .resizable()
                .scaledToFit()
                .frame(maxHeight: 300)
                .clipShape(RoundedRectangle(cornerRadius: 8))
        } else {
            HStack(spacing: 4) {
                Image(systemName: "photo")
                Text("Image")
            }
            .font(.caption)
            .foregroundStyle(Theme.mutedForeground(for: colorScheme))
        }
    }

    @ViewBuilder
    private var fileView: some View {
        HStack(spacing: 6) {
            Image(systemName: "doc")
                .font(.caption)
            Text(block.fileName ?? "File")
                .font(.caption.monospaced())
        }
        .foregroundStyle(Theme.mutedForeground(for: colorScheme))
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Theme.muted(for: colorScheme).opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private func findToolResult(for toolUseBlock: ContentBlock) -> ContentBlock? {
        guard let toolUseId = toolUseBlock.resolvedToolUseId ?? toolUseBlock.toolCallId else { return nil }
        return allBlocks.first { $0.type == .toolResult && ($0.resolvedToolUseId == toolUseId || $0.toolCallId == toolUseId) }
    }

    private func stripSuggestedPrompts(_ text: String) -> String {
        // Only well-formed suggested-prompts blocks are removed; body text
        // that merely looks like one is left intact (see `SuggestedPrompts`).
        var result = SuggestedPrompts.stripBlocks(from: text)

        // Strip all other HTML comments. Suggested-prompts openers (which end
        // their line) are excluded so a malformed one cannot lazily capture body
        // text up to an embedded `-->` (e.g. a Mermaid edge).
        result = result.replacingOccurrences(
            of: "<!--(?![ \\t]*suggested-prompts[ \\t]*(\\r?\\n|$))[\\s\\S]*?-->",
            with: "",
            options: .regularExpression
        )

        // Strip agent_digest tags
        result = result.replacingOccurrences(
            of: "<agent_digest>[\\s\\S]*?</agent_digest>",
            with: "",
            options: .regularExpression
        )

        // Strip supervisor tags
        result = result.replacingOccurrences(
            of: "<supervisor>[\\s\\S]*?</supervisor>",
            with: "",
            options: .regularExpression
        )

        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

