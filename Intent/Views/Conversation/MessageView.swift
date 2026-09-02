import SwiftUI

struct MessageView: View {
    let message: ConversationMessage
    let workspaceId: String
    var onNavigateToNote: ((_ noteId: String, _ workspaceId: String, _ noteTitle: String) -> Void)? = nil
    var onNavigateToAgent: ((_ agentId: String, _ workspaceId: String, _ agentName: String) -> Void)? = nil
    /// Block ids of this message with a slim-projection hydration fetch in
    /// flight (agent.getMessageBlock, PROTOCOL §5.5).
    var hydratingBlockIds: Set<String> = []
    /// Fetch the full body of a slim-truncated block of this message by id.
    var onHydrateBlock: ((_ blockId: String) -> Void)? = nil
    @Environment(\.colorScheme) var colorScheme
    /// Agent-to-agent rows render as a collapsed disclosure card; the body
    /// is hidden until the header is tapped (FE parity: ChatMessage.svelte
    /// `isAgentMessageExpanded`, collapsed by default).
    @State private var isAgentMessageExpanded = false

    private var isUser: Bool { message.role == .user }
    private var blocks: [ContentBlock] { message.contentBlocks ?? [] }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Dismissal notification rows render as a compact divider chip
            // regardless of the persisted role (PROTOCOL §5.5
            // `questions_dismissed`; FE parity: ChatMessage.svelte).
            if let dismissedNotice = message.questionsDismissedNotice {
                QuestionsDismissedNoticeView(notice: dismissedNotice)
            } else if let modelChange = message.modelChangeNotice {
                // Model-change rows (`metadata.type = "model_changed"`) are
                // informational and render as a centered divider chip
                // regardless of the persisted role (PROTOCOL §5.5
                // `agent.setModel`; FE parity: ChatMessage.svelte checks
                // getModelChangeNotice before any role branching).
                ModelChangeNoticeView(
                    notice: modelChange, fallbackText: message.joinedTextContent)
            } else if isUser, let eventWake = message.eventWakeAttribution {
                // Event-notification wake rows render as a compact banner —
                // the whole body is machine text, so the banner replaces the
                // bubble (display-only; FE parity: EventWakeupBanner).
                EventWakeBannerView(attribution: eventWake)
            } else if isUser {
                userMessageView
            } else if message.role == .assistant {
                assistantMessageView
            } else if message.role == .error {
                errorMessageView
            } else if message.role == .system {
                // Attention-request / turn-failure rows get a kind-flavored
                // card; every other system row (e.g. `meta.kind =
                // "interruption"`) falls back to a generic muted banner
                // instead of rendering nothing (FE parity:
                // ChatMessage.svelte system branch).
                if let notice = message.attentionNotice {
                    AttentionNoticeView(notice: notice)
                } else {
                    SystemNoticeBannerView(message: message.joinedTextContent)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var userMessageView: some View {
        // Wake attribution (PROTOCOL §5.40 / §5.42): hook and PR-monitor wake
        // rows replace the "You" header with an attribution header and get
        // the machine prefix/state note display-stripped from the body.
        // Agent-to-agent sends (`metadata.type == "agent_message"`) render
        // as a collapsed disclosure card: sender header + one-line preview,
        // body hidden until expanded (FE parity: ChatMessage.svelte).
        // Absent/malformed metadata falls back to the plain user rendering.
        let hookWake = message.hookWakeAttribution
        let prWake = hookWake == nil ? message.prMonitorWakeAttribution : nil
        let agentMessage = hookWake == nil && prWake == nil ? message.agentMessageAttribution : nil

        VStack(alignment: .leading, spacing: 4) {
            if let hookWake {
                HookWakeAttributionView(attribution: hookWake)
            } else if let prWake {
                PrMonitorWakeAttributionView(attribution: prWake, workspaceRepo: workspaceRepo)
            } else if let agentMessage {
                AgentMessageAttributionView(
                    attribution: agentMessage,
                    preview: Self.agentMessagePreview(from: blocks),
                    isExpanded: $isAgentMessageExpanded,
                    onOpenAgent: onNavigateToAgent.map { navigate in
                        { navigate(agentMessage.fromAgentId, workspaceId, agentMessage.rawName) }
                    }
                )
            } else {
                Text("You")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.mutedForeground(for: colorScheme))
            }

            if agentMessage == nil || isAgentMessageExpanded {
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
                            ImageAttachmentThumbnail(block: block, workspaceId: workspaceId)
                        }
                    }
                    .padding(.top, 4)
                }

                // Attached files render last as compact name + size chips
                // (FE parity: ChatMessage.svelte attachment chips).
                if !partitioned.files.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(partitioned.files) { block in
                            fileAttachmentChip(block)
                        }
                    }
                    .padding(.top, 4)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.muted(for: colorScheme).opacity(0.4))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .modifier(MessageCopyContextMenu(
            text: Self.userCopyText(from: blocks, hookWake: hookWake, prWake: prWake),
            userStyled: true,
            isStreaming: false
        ))
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
            // Message-level suggested-prompts strip runs BEFORE grouping so a
            // block whose opener and closer land in different text blocks is
            // still removed (per-block stripping in ContentBlockView can't
            // see across boundaries — intent-hq/intent#3936).
            let strippedBlocks = SuggestedPrompts.parse(contentBlocks: blocks).contentBlocks
            let renderBlocks = Self.groupContentBlocks(strippedBlocks, isStreaming: message.isStreaming == true)

            ForEach(Array(renderBlocks.enumerated()), id: \.element.id) { index, renderBlock in
                switch renderBlock {
                case .contentBlock(let block):
                    ContentBlockView(
                        block: block, allBlocks: blocks, workspaceId: workspaceId,
                        onNavigateToNote: onNavigateToNote,
                        hydratingBlockIds: hydratingBlockIds,
                        onHydrateBlock: onHydrateBlock)
                case .group(let group):
                    let isLastGroup = !renderBlocks.suffix(from: index + 1).contains(where: {
                        if case .group = $0 { return true }
                        return false
                    })
                    ResponseGroupView(
                        group: group, isLast: isLastGroup, workspaceId: workspaceId,
                        onNavigateToNote: onNavigateToNote,
                        hydratingBlockIds: hydratingBlockIds,
                        onHydrateBlock: onHydrateBlock)
                }
            }


        }
        .padding(.vertical, 4)
        .modifier(MessageCopyContextMenu(
            text: Self.assistantCopyText(from: blocks),
            userStyled: false,
            isStreaming: message.isStreaming == true
        ))
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

    /// The string copied from a user row: only the text blocks the row
    /// renders (`partitionUserBlocks` drops code and other block types, so
    /// copy can never include content that isn't visible), transformed by
    /// `plainTextContent`.
    static func userCopyText(
        from blocks: [ContentBlock],
        hookWake: HookWakeAttribution? = nil,
        prWake: PrMonitorWakeAttribution? = nil
    ) -> String {
        plainTextContent(from: partitionUserBlocks(blocks).text, hookWake: hookWake, prWake: prWake)
    }

    /// One-line preview for a collapsed agent-to-agent disclosure card: the
    /// row's rendered text (`userCopyText` — supervisor tags stripped,
    /// `@context[...]` tokens replaced with titles) with whitespace runs
    /// including newlines collapsed to single spaces, so the header shows a
    /// clean single line (FE parity: ChatMessage.svelte
    /// `agentMessagePreview` + its single-line truncation).
    static func agentMessagePreview(from blocks: [ContentBlock]) -> String {
        userCopyText(from: blocks)
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// The string copied from an assistant row: the displayed text, not the
    /// raw payload. Blocks go through the same `groupContentBlocks` pass as
    /// rendering (so `<group:…>` tags never leak into the copy; grouped
    /// children are flattened back in order) and each text block gets the
    /// same protocol-block cleaning as `ContentBlockView` (suggested-prompts
    /// blocks, HTML comments, `<agent_digest>` and supervisor tags). Code
    /// blocks are kept verbatim; tool, thinking and image blocks are skipped.
    static func assistantCopyText(from blocks: [ContentBlock]) -> String {
        // Same message-level pre-strip as assistantMessageView so copy
        // matches the display when markup spans text-block boundaries.
        let stripped = SuggestedPrompts.parse(contentBlocks: blocks).contentBlocks
        let displayed: [ContentBlock] = groupContentBlocks(stripped).flatMap { renderBlock -> [ContentBlock] in
            switch renderBlock {
            case .contentBlock(let block): return [block]
            case .group(let group): return group.children
            }
        }
        return displayed.compactMap { block -> String? in
            switch block.type {
            case .text:
                guard let text = block.resolvedText else { return nil }
                let cleaned = ContentBlockView.stripSuggestedPrompts(text)
                return cleaned.isEmpty ? nil : cleaned
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

    /// Split a user row's blocks into text blocks (rendered first), image
    /// blocks (rendered after, as a thumbnail row), and file blocks (rendered
    /// last, as name + size chips), preserving relative order within each
    /// kind regardless of interleaving in the payload. Other block types
    /// don't render in user rows.
    static func partitionUserBlocks(_ blocks: [ContentBlock]) -> (text: [ContentBlock], images: [ContentBlock], files: [ContentBlock]) {
        (blocks.filter { $0.type == .text },
         blocks.filter { $0.type == .image },
         blocks.filter { $0.type == .file })
    }

    /// A sent file attachment chip on a user row: doc icon, file name, and
    /// byte size when the persisted block carries one (PROTOCOL §5.5 file
    /// block: `{ type: "file", attachmentId, fileName, mimeType?, size? }`).
    private func fileAttachmentChip(_ block: ContentBlock) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "doc.fill")
                .font(.caption)
                .foregroundStyle(Theme.mutedForeground(for: colorScheme))
            Text(block.fileName ?? "Attachment")
                .font(.caption)
                .lineLimit(1)
            if let size = block.size {
                Text(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))
                    .font(.caption2)
                    .foregroundStyle(Theme.mutedForeground(for: colorScheme))
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(Theme.muted(for: colorScheme).opacity(0.6))
        .clipShape(RoundedRectangle(cornerRadius: 8))
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

    private static let groupTagRegex = #/<group:([^>\n<]+)>|<\/group(:[^>\n<]+)?>/#
    private static let incompleteGroupTagRegex = #/<\/?g(?:r(?:o(?:u(?:p(?::?[^>\n<]*)?)?)?)?)?$/#

    /// Parse `<group:Name>` and `</group>` tags from text ContentBlocks,
    /// grouping all blocks (text, tool_use, tool_result, etc.) that appear
    /// between open/close tags into ResponseGroup objects.
    static func groupContentBlocks(_ blocks: [ContentBlock], isStreaming: Bool = false) -> [RenderBlock] {
        var result: [RenderBlock] = []
        var currentGroup: (id: String, name: String, children: [ContentBlock])? = nil
        // Deterministic identities: synthetic segments and groups derive their
        // ids from the source block they were parsed out of, so re-parsing the
        // same input yields the same ids and streaming deltas don't tear down
        // already-rendered views (or reset a group's expansion State).
        // The `#seg<n>` / `#group<n>:<name>` suffix scheme assumes source
        // block ids never contain those literal markers (server ids are
        // UUID-like); revisit if block ids ever become caller-controlled. A
        // collision would only perturb SwiftUI view identity within this one
        // message's render pass, never the underlying block data.
        var segmentCounts: [String: Int] = [:]
        var groupOrdinals: [String: Int] = [:]

        func addBlock(_ block: ContentBlock) {
            if currentGroup != nil {
                currentGroup!.children.append(block)
            } else {
                result.append(.contentBlock(block))
            }
        }

        func nextSegmentId(from source: ContentBlock) -> String {
            let index = segmentCounts[source.id, default: 0]
            segmentCounts[source.id] = index + 1
            // The first segment reuses the source block's own id: a block
            // with no group tags passes through under its raw id, so when a
            // tag later streams into the block the already-rendered leading
            // run keeps its identity instead of flipping to a synthetic id.
            return index == 0 ? source.id : "\(source.id)#seg\(index)"
        }

        func addTextIfNonEmpty(_ text: String, from source: ContentBlock) {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                addBlock(ContentBlock(id: nextSegmentId(from: source), type: .text, text: trimmed))
            }
        }

        func closeCurrentGroup() {
            if let group = currentGroup {
                result.append(.group(ResponseGroup(id: group.id, name: group.name, children: group.children)))
                currentGroup = nil
            }
        }

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
            if isStreaming {
                processedText = processedText.replacing(Self.incompleteGroupTagRegex, with: "")
                if processedText.isEmpty { continue }
            }

            // Scan this text block for group tags
            let matches = processedText.matches(of: Self.groupTagRegex)

            if matches.isEmpty {
                // No group tags — pass through as-is
                if processedText == blockText {
                    addBlock(block)
                } else {
                    addBlock(ContentBlock(id: nextSegmentId(from: block), type: .text, text: processedText))
                }
                continue
            }

            var lastIndex = processedText.startIndex
            for match in matches {
                let matchStart = match.range.lowerBound
                let matchEnd = match.range.upperBound

                if let capturedName = match.output.1 {
                    // Open tag: <group:Name>
                    let groupName = String(capturedName).trimmingCharacters(in: .whitespaces)

                    // Text before the tag
                    if matchStart > lastIndex {
                        addTextIfNonEmpty(String(processedText[lastIndex..<matchStart]), from: block)
                    }

                    // Auto-close previous group if one is open
                    closeCurrentGroup()

                    // Group identity derives from the opening tag's source
                    // block, its per-block ordinal and its name — stable from
                    // the moment the group opens, before its close tag streams in.
                    let ordinal = groupOrdinals[block.id, default: 0]
                    groupOrdinals[block.id] = ordinal + 1
                    currentGroup = (id: "\(block.id)#group\(ordinal):\(groupName)", name: groupName, children: [])
                } else {
                    // Close tag: </group> or </group:Name>
                    if matchStart > lastIndex {
                        addTextIfNonEmpty(String(processedText[lastIndex..<matchStart]), from: block)
                    }
                    closeCurrentGroup()
                }

                lastIndex = matchEnd
            }

            // Remaining text after last tag
            if lastIndex < processedText.endIndex {
                addTextIfNonEmpty(String(processedText[lastIndex...]), from: block)
            }
        }

        // Handle unclosed group at end
        closeCurrentGroup()

        return result
    }
}

// MARK: - Copy context menu with upright preview

/// "Copy" context menu that stays upright through every phase of the
/// press → menu transition. Transcript rows sit inside the flipped
/// inverted-scroll hierarchy (ConversationView's FlippedUpsideDown), and
/// UIKit's default lift/highlight snapshot mishandles the rotation/scale
/// transforms. SwiftUI's `.contextMenu` can only replace the OPEN preview
/// (which an earlier fix did) — it exposes no hook over the lift snapshot,
/// so the lift animation still flashed a mirrored/upside-down copy of the
/// row while the long press was being recognized. The row therefore gets a
/// `CopyContextMenuOverlay`, a transparent UIKit view carrying a
/// `UIContextMenuInteraction` whose delegate supplies an upright
/// `UITargetedPreview` for the highlight and dismissal phases — the only
/// API that controls those frames. The row content itself stays in the
/// plain SwiftUI hierarchy: the overlay is applied unconditionally, so
/// enabling/disabling the interaction never changes the row's structural
/// identity (a previous host-based version flipped the subtree into a
/// nested `UIHostingController` at turn settle, resetting row state —
/// intent-hq/monorepo#3441 — and its self-sizing drew a garbled first
/// frame on conversation load). The copy action puts `text` on the general
/// pasteboard with light haptic feedback (matching CodeBlockView's copy
/// affordance). No interaction is attached when there is no text to copy
/// (e.g. image-only rows) or while the message is still streaming; it
/// attaches once the turn settles. Long text is capped by line limit and
/// width so the preview shows a truncated excerpt.
struct MessageCopyContextMenu: ViewModifier {
    let text: String
    /// Mirror the user-bubble styling (muted rounded rect) in the preview.
    let userStyled: Bool
    /// Whether the message is still streaming; live rows carry no copy
    /// interaction (user rows never stream and always pass false).
    let isStreaming: Bool
    @Environment(\.colorScheme) private var colorScheme

    /// Whether the overlay should attach the copy interaction: only when
    /// there is text to copy AND the message has settled. Kept as a pure
    /// helper so the availability decision is unit-testable.
    static func shouldEnableCopyInteraction(text: String, isStreaming: Bool) -> Bool {
        !text.isEmpty && !isStreaming
    }

    func body(content: Content) -> some View {
        content.overlay {
            CopyContextMenuOverlay(
                text: text,
                isEnabled: Self.shouldEnableCopyInteraction(text: text, isStreaming: isStreaming),
                preview: AnyView(preview)
            )
        }
    }

    /// Same appearance as the previous SwiftUI `preview:` closure.
    private var preview: some View {
        Text(text)
            .font(.subheadline)
            .foregroundStyle(Theme.foreground(for: colorScheme).opacity(userStyled ? 0.85 : 1))
            .lineLimit(Constants.Conversation.Message.contextPreviewLineLimit)
            .padding(12)
            .frame(maxWidth: Constants.Conversation.Message.contextPreviewMaximumWidth, alignment: .leading)
            .background(userStyled ? Theme.muted(for: colorScheme).opacity(0.4) : .clear)
            .background(Theme.background(for: colorScheme))
    }
}

