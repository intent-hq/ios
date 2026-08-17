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
        // Wake attribution (PROTOCOL §5.40 / §5.42): hook and PR-monitor wake
        // rows replace the "You" header with an attribution header and get
        // the machine prefix/state note display-stripped from the body.
        // Absent/malformed metadata falls back to the plain user rendering.
        let hookWake = message.hookWakeAttribution
        let prWake = hookWake == nil ? message.prMonitorWakeAttribution : nil

        VStack(alignment: .leading, spacing: 4) {
            if let hookWake {
                HookWakeAttributionView(attribution: hookWake)
            } else if let prWake {
                PrMonitorWakeAttributionView(attribution: prWake, workspaceRepo: workspaceRepo)
            } else {
                Text("You")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.mutedForeground(for: colorScheme))
            }

            let partitioned = Self.partitionUserBlocks(blocks)

            ForEach(partitioned.text) { block in
                if let text = block.resolvedText {
                    userTextBlock(text, hookWake: hookWake, prWake: prWake)
                }
            }

            // Attached images render after the text as a left-aligned wrapping
            // row of square thumbnails, regardless of block order in the
            // payload (FE parity: ChatMessage.svelte attached images).
            if !partitioned.images.isEmpty {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: ImageAttachmentThumbnail.side, maximum: ImageAttachmentThumbnail.side), spacing: 6)],
                    alignment: .leading,
                    spacing: 6
                ) {
                    ForEach(partitioned.images) { block in
                        ImageAttachmentThumbnail(block: block)
                    }
                }
                .padding(.top, 4)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.muted(for: colorScheme).opacity(0.4))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .contextMenu {
            copyMenuItem(Self.plainTextContent(from: blocks, hookWake: hookWake, prWake: prWake))
        }
    }

    /// A user-row text block: wake rows get the daemon's literal
    /// `[Background hook "…"]` / `[PR monitor …]` prefix (plus the trailing
    /// `[This hook …]` state note for hook wakes) stripped display-only — the
    /// attribution header already names the hook / PR and conveys the
    /// post-fire state — and drop the block entirely when nothing remains.
    /// `@context[...]` tokens render as compact chips (FE parity:
    /// ChatMessage.svelte inline mentions) instead of raw base64 walls.
    @ViewBuilder
    private func userTextBlock(
        _ text: String,
        hookWake: HookWakeAttribution?,
        prWake: PrMonitorWakeAttribution?
    ) -> some View {
        let display: String = {
            if let hookWake { return Self.stripSupervisorTags(HookWakeAttribution.displayText(text, attribution: hookWake)) }
            if prWake != nil { return Self.stripSupervisorTags(PrMonitorWakeAttribution.displayText(text)) }
            return Self.stripSupervisorTags(text)
        }()
        if (hookWake == nil && prWake == nil) || !display.isEmpty {
            let rows = Self.userTextRows(display)
            if rows.contains(where: { if case .chips = $0 { return true } else { return false } }) {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                        switch row {
                        case .text(let run):
                            userText(run)
                        case .chips(let mentions):
                            ChipFlowLayout(spacing: 6) {
                                ForEach(Array(mentions.enumerated()), id: \.offset) { _, mention in
                                    ContextMentionChipView(mention: mention)
                                }
                            }
                        }
                    }
                }
            } else {
                userText(display)
            }
        }
    }

    private func userText(_ text: String) -> some View {
        Text(text)
            .font(.subheadline)
            .foregroundStyle(Theme.foreground(for: colorScheme).opacity(0.85))
            .textSelection(.enabled)
    }

    /// `<owner>/<repo>` of this message's workspace, or nil when unknown
    /// (one-time read; the PR chip label then falls back to the bare `#<n>`).
    private var workspaceRepo: String? {
        guard let ws = WorkspaceStore.shared.workspaces.first(where: { $0.id == workspaceId }),
              let owner = ws.repositoryOwner, let name = ws.repositoryName else { return nil }
        return "\(owner)/\(name)"
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
        .contextMenu {
            copyMenuItem(Self.plainTextContent(from: blocks))
        }
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

    /// "Copy" context-menu item putting `text` on the general pasteboard with
    /// light haptic feedback (matching CodeBlockView's copy affordance).
    /// Renders nothing when there is no text to copy (e.g. image-only rows).
    @ViewBuilder
    private func copyMenuItem(_ text: String) -> some View {
        if !text.isEmpty {
            Button {
                HapticManager.impact(.light)
                UIPasteboard.general.string = text
            } label: {
                Label("Copy", systemImage: "doc.on.doc")
            }
        }
    }

    /// Extract plain text content from content blocks for clipboard copy.
    /// Text and code blocks are joined with blank lines; tool, thinking and
    /// image blocks are skipped. Supervisor tags are stripped and
    /// `@context[...]` tokens are replaced with their decoded titles so
    /// copies aren't base64 walls; on wake rows, pass the row's attribution
    /// so the machine wake prefix (and hook state note) is stripped like the
    /// display. Blocks left empty by stripping are dropped.
    static func plainTextContent(
        from blocks: [ContentBlock],
        hookWake: HookWakeAttribution? = nil,
        prWake: PrMonitorWakeAttribution? = nil
    ) -> String {
        blocks.compactMap { block -> String? in
            switch block.type {
            case .text:
                guard var text = block.resolvedText else { return nil }
                if let hookWake {
                    text = HookWakeAttribution.displayText(text, attribution: hookWake)
                } else if prWake != nil {
                    text = PrMonitorWakeAttribution.displayText(text)
                }
                let plain = ContextMention.replacingTokensWithTitles(in: stripSupervisorTags(text))
                return plain.isEmpty ? nil : plain
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

    // MARK: - User block partitioning

    /// Split a user row's blocks into text blocks (rendered first) and image
    /// blocks (rendered after, as a thumbnail row), preserving relative order
    /// within each kind regardless of interleaving in the payload. Other
    /// block types don't render in user rows.
    static func partitionUserBlocks(_ blocks: [ContentBlock]) -> (text: [ContentBlock], images: [ContentBlock]) {
        (blocks.filter { $0.type == .text }, blocks.filter { $0.type == .image })
    }

    // MARK: - User text rows

    /// A row of a user text block: a plain-text run or a run of context
    /// chips (consecutive mentions collapse into one wrapping chip row).
    enum UserTextRow: Equatable {
        case text(String)
        case chips([ContextMention])
    }

    /// Split user-message text into vertically stacked rows: plain-text runs
    /// (trimmed; whitespace-only runs dropped) and chip rows. Consecutive
    /// mentions separated only by whitespace share one chip row so a message
    /// that leads with several tokens renders as a single wrapping row.
    static func userTextRows(_ text: String) -> [UserTextRow] {
        var rows: [UserTextRow] = []
        for segment in ContextMention.segments(from: text) {
            switch segment {
            case .text(let run):
                let trimmed = run.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { rows.append(.text(trimmed)) }
            case .mention(let mention):
                if case .chips(let chips)? = rows.last {
                    rows[rows.count - 1] = .chips(chips + [mention])
                } else {
                    rows.append(.chips([mention]))
                }
            }
        }
        return rows
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

