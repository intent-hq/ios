import SwiftUI

struct MessageView: View {
    let message: ConversationMessage
    let workspaceId: String
    var onNavigateToNote: ((_ noteId: String, _ workspaceId: String, _ noteTitle: String) -> Void)? = nil
    @Environment(\.colorScheme) var colorScheme

    private var isUser: Bool { message.role == .user }
    private var blocks: [ContentBlock] { message.contentBlocks ?? [] }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Dismissal notification rows render as a compact divider chip
            // regardless of the persisted role (PROTOCOL §5.5
            // `questions_dismissed`; FE parity: ChatMessage.svelte).
            if let dismissedNotice = message.questionsDismissedNotice {
                QuestionsDismissedNoticeView(notice: dismissedNotice)
            } else if isUser {
                userMessageView
            } else if message.role == .assistant {
                assistantMessageView
            } else if message.role == .error {
                errorMessageView
            } else if message.role == .system, let notice = message.attentionNotice {
                AttentionNoticeView(notice: notice)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var userMessageView: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("You")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Theme.mutedForeground(for: colorScheme))

            ForEach(blocks) { block in
                if block.type == .text, let text = block.resolvedText {
                    Text(Self.stripSupervisorTags(text))
                        .font(.subheadline)
                        .foregroundStyle(Theme.foreground(for: colorScheme).opacity(0.85))
                        .textSelection(.enabled)
                } else if block.type == .image {
                    ContentBlockView(block: block, allBlocks: blocks, workspaceId: workspaceId, onNavigateToNote: onNavigateToNote)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.muted(for: colorScheme).opacity(0.4))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder
    private var assistantMessageView: some View {
        VStack(alignment: .leading, spacing: 8) {
            let renderBlocks = Self.groupContentBlocks(blocks, isStreaming: message.isStreaming == true)

            ForEach(Array(renderBlocks.enumerated()), id: \.element.id) { index, renderBlock in
                switch renderBlock {
                case .contentBlock(let block):
                    ContentBlockView(block: block, allBlocks: blocks, workspaceId: workspaceId, onNavigateToNote: onNavigateToNote)
                case .group(let group):
                    let isLastGroup = !renderBlocks.suffix(from: index + 1).contains(where: {
                        if case .group = $0 { return true }
                        return false
                    })
                    ResponseGroupView(group: group, isLast: isLastGroup, workspaceId: workspaceId, onNavigateToNote: onNavigateToNote)
                }
            }


        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var errorMessageView: some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Theme.destructive(for: colorScheme))
            Text(message.error ?? "An error occurred")
                .font(.callout)
                .foregroundStyle(Theme.destructive(for: colorScheme))
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.destructive(for: colorScheme).opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Plain text extraction

    /// Extract plain text content from content blocks for clipboard copy.
    private static func plainTextContent(from blocks: [ContentBlock]) -> String {
        blocks.compactMap { block -> String? in
            switch block.type {
            case .text:
                if let text = block.resolvedText {
                    return stripSupervisorTags(text)
                }
                return nil
            case .code:
                return block.resolvedText
            default:
                return nil
            }
        }.joined(separator: "\n\n")
    }

    // MARK: - Text stripping

    private static func stripSupervisorTags(_ text: String) -> String {
        text.replacingOccurrences(
            of: "<supervisor>[\\s\\S]*?</supervisor>",
            with: "",
            options: .regularExpression
        ).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Group parsing from blocks

    /// Parse `<group:Name>` and `</group>` tags from text ContentBlocks,
    /// grouping all blocks (text, tool_use, tool_result, etc.) that appear
    /// between open/close tags into ResponseGroup objects.
    static func groupContentBlocks(_ blocks: [ContentBlock], isStreaming: Bool = false) -> [RenderBlock] {
        // Regex to match <group:Name> or </group> or </group:Name>
        let tagPattern = "<group:([^>\\n<]+)>|</group(:[^>\\n<]+)?>"
        guard let regex = try? NSRegularExpression(pattern: tagPattern) else {
            return blocks.map { .contentBlock($0) }
        }

        var result: [RenderBlock] = []
        var currentGroup: (name: String, children: [ContentBlock])? = nil

        func addBlock(_ block: ContentBlock) {
            if currentGroup != nil {
                currentGroup!.children.append(block)
            } else {
                result.append(.contentBlock(block))
            }
        }

        func addTextIfNonEmpty(_ text: String) {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                addBlock(ContentBlock(type: .text, text: trimmed))
            }
        }

        func closeCurrentGroup() {
            if let group = currentGroup {
                result.append(.group(ResponseGroup(name: group.name, children: group.children)))
                currentGroup = nil
            }
        }

        // Regex to strip trailing incomplete group tags during streaming.
        // Matches a trailing `<` followed by partial `group:...` or `/group...` with no closing `>`.
        let incompleteTagPattern = "</?g(?:r(?:o(?:u(?:p(?::?[^>\\n<]*)?)?)?)?)?$"
        let incompleteTagRegex = isStreaming ? (try? NSRegularExpression(pattern: incompleteTagPattern)) : nil

        for block in blocks {
            guard block.type == .text, let blockText = block.resolvedText, !blockText.isEmpty else {
                // Non-text block or empty text — pass through into current context
                if block.type != .text {
                    addBlock(block)
                }
                continue
            }

            // During streaming, strip any trailing incomplete <group:...> or </group...> tag
            var processedText = blockText
            if let incompleteRegex = incompleteTagRegex {
                let nsBlock = processedText as NSString
                let range = NSRange(location: 0, length: nsBlock.length)
                processedText = incompleteRegex.stringByReplacingMatches(in: processedText, range: range, withTemplate: "")
                if processedText.isEmpty { continue }
            }

            // Scan this text block for group tags
            let nsText = processedText as NSString
            let matches = regex.matches(in: processedText, range: NSRange(location: 0, length: nsText.length))

            if matches.isEmpty {
                // No group tags — pass through as-is
                if processedText == blockText {
                    addBlock(block)
                } else {
                    addBlock(ContentBlock(type: .text, text: processedText))
                }
                continue
            }

            var lastIndex = 0
            for match in matches {
                let matchStart = match.range.location
                let matchEnd = matchStart + match.range.length

                if match.range(at: 1).location != NSNotFound {
                    // Open tag: <group:Name>
                    let groupName = nsText.substring(with: match.range(at: 1)).trimmingCharacters(in: .whitespaces)

                    // Text before the tag
                    if matchStart > lastIndex {
                        addTextIfNonEmpty(nsText.substring(with: NSRange(location: lastIndex, length: matchStart - lastIndex)))
                    }

                    // Auto-close previous group if one is open
                    closeCurrentGroup()

                    currentGroup = (name: groupName, children: [])
                } else {
                    // Close tag: </group> or </group:Name>
                    if matchStart > lastIndex {
                        addTextIfNonEmpty(nsText.substring(with: NSRange(location: lastIndex, length: matchStart - lastIndex)))
                    }
                    closeCurrentGroup()
                }

                lastIndex = matchEnd
            }

            // Remaining text after last tag
            if lastIndex < nsText.length {
                addTextIfNonEmpty(nsText.substring(with: NSRange(location: lastIndex, length: nsText.length - lastIndex)))
            }
        }

        // Handle unclosed group at end
        closeCurrentGroup()

        return result
    }
}

