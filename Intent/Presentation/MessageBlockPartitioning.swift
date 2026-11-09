import Foundation

extension ContentBlock {
    var isToolActivity: Bool { type == .toolUse || type == .thinking }
}

struct UserBlockPartition {
    let text: [ContentBlock]
    let images: [ContentBlock]
    let videos: [ContentBlock]
    let files: [ContentBlock]
}

enum MessageBlockPartitioning {
    static func plainTextContent(
        from blocks: [ContentBlock],
        hookWake: HookWakeAttribution? = nil,
        prWake: PrMonitorWakeAttribution? = nil,
        agentMessage: AgentMessageAttribution? = nil
    ) -> String {
        let firstTextIndex = blocks.firstIndex { $0.type == .text }
        return blocks.indices.compactMap { index -> String? in
            let block = blocks[index]
            switch block.type {
            case .text:
                guard var text = block.resolvedText else { return nil }
                if let hookWake {
                    text = HookWakeAttribution.displayText(text, attribution: hookWake)
                } else if prWake != nil {
                    text = PrMonitorWakeAttribution.displayText(text)
                } else if let agentMessage, index == firstTextIndex {
                    text = AgentMessageAttribution.stripSenderHeader(text, attribution: agentMessage)
                }
                let plain = ContextMention.replacingTokensWithTitles(
                    in: stripSupervisorTags(text)
                )
                return plain.isEmpty ? nil : plain
            case .code:
                return block.resolvedText
            default:
                return nil
            }
        }
        .joined(separator: "\n\n")
    }

    static func userCopyText(
        from blocks: [ContentBlock],
        hookWake: HookWakeAttribution? = nil,
        prWake: PrMonitorWakeAttribution? = nil,
        agentMessage: AgentMessageAttribution? = nil
    ) -> String {
        plainTextContent(
            from: partitionUserBlocks(blocks).text,
            hookWake: hookWake,
            prWake: prWake,
            agentMessage: agentMessage
        )
    }

    static func agentMessagePreview(
        from blocks: [ContentBlock],
        agentMessage: AgentMessageAttribution? = nil
    ) -> String {
        userCopyText(from: blocks, agentMessage: agentMessage)
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    static func assistantCopyText(from blocks: [ContentBlock]) -> String {
        let stripped = SuggestedPrompts.parse(contentBlocks: blocks).contentBlocks
        let displayed: [ContentBlock] = groupContentBlocks(stripped).flatMap { renderBlock in
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
        }
        .joined(separator: "\n\n")
    }

    /// `tool_result` blocks keyed by the id of the `tool_use` block they
    /// answer (matched on `resolvedToolUseId` / `toolCallId`, first match
    /// wins). Computed once per message so each block row receives only its
    /// own result value instead of the whole block array.
    static func pairToolResults(_ blocks: [ContentBlock]) -> [String: ContentBlock] {
        let results = blocks.filter { $0.type == .toolResult }
        guard !results.isEmpty else { return [:] }
        var paired: [String: ContentBlock] = [:]
        for block in blocks where block.type == .toolUse {
            guard let toolUseId = block.resolvedToolUseId ?? block.toolCallId else { continue }
            paired[block.id] = results.first { $0.resolvedToolUseId == toolUseId || $0.toolCallId == toolUseId }
        }
        return paired
    }

    static func stripSupervisorTags(_ text: String) -> String {
        text.replacingOccurrences(
            of: "<supervisor>[\\s\\S]*?</supervisor>",
            with: "",
            options: .regularExpression
        )
        .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func partitionUserBlocks(
        _ blocks: [ContentBlock]
    ) -> UserBlockPartition {
        var text: [ContentBlock] = []
        var images: [ContentBlock] = []
        var videos: [ContentBlock] = []
        var files: [ContentBlock] = []
        for block in blocks {
            switch block.type {
            case .text:
                text.append(block)
            case .image, .file:
                let path = block.fileName ?? ""
                if let attachmentId = block.attachmentId, !attachmentId.isEmpty,
                   WorkspaceVideo.isVideo(path: path, mimeType: block.mimeType) {
                    if WorkspaceVideo.isWebM(path: path, mimeType: block.mimeType) {
                        files.append(block)
                    } else {
                        videos.append(block)
                    }
                } else if block.type == .image {
                    images.append(block)
                } else {
                    files.append(block)
                }
            default:
                break
            }
        }
        return UserBlockPartition(text: text, images: images, videos: videos, files: files)
    }

    private static let groupTagRegex = #/<group:([^>\r\n<]+)>|<\/group(:[^>\r\n<]+)?>/#
    private static let incompleteGroupTagRegex = #/<\/?g(?:r(?:o(?:u(?:p(?::?[^>\r\n<]*)?)?)?)?)?$/#

    static func groupContentBlocks(
        _ blocks: [ContentBlock],
        isStreaming: Bool = false
    ) -> [RenderBlock] {
        var partitioner = GroupContentBlockPartitioner(isStreaming: isStreaming)
        return partitioner.partition(blocks)
    }

    private struct ActiveResponseGroup {
        let id: String
        let name: String
        var children: [ContentBlock]
    }

    private struct GroupContentBlockPartitioner {
        let isStreaming: Bool
        var result: [RenderBlock] = []
        var currentGroup: ActiveResponseGroup?
        var segmentCounts: [String: Int] = [:]
        var groupOrdinals: [String: Int] = [:]

        mutating func partition(_ blocks: [ContentBlock]) -> [RenderBlock] {
            for block in blocks {
                process(block)
            }
            closeCurrentGroup()
            return result
        }

        private mutating func process(_ block: ContentBlock) {
            guard block.type == .text,
                  let blockText = block.resolvedText,
                  !blockText.isEmpty else {
                if block.type != .text { addBlock(block) }
                return
            }
            var processedText = blockText
            if isStreaming {
                processedText = processedText.replacing(
                    MessageBlockPartitioning.incompleteGroupTagRegex,
                    with: ""
                )
                if processedText.isEmpty { return }
            }
            let matches = processedText.matches(of: MessageBlockPartitioning.groupTagRegex)
            guard !matches.isEmpty else {
                addUngroupedText(processedText, originalText: blockText, source: block)
                return
            }
            processMatches(in: processedText, source: block)
        }

        private mutating func addUngroupedText(
            _ processedText: String,
            originalText: String,
            source: ContentBlock
        ) {
            if processedText == originalText {
                addBlock(source)
            } else {
                addBlock(ContentBlock(
                    id: nextSegmentId(from: source),
                    type: .text,
                    text: processedText
                ))
            }
        }

        private mutating func processMatches(in text: String, source: ContentBlock) {
            var lastIndex = text.startIndex
            for match in text.matches(of: MessageBlockPartitioning.groupTagRegex) {
                let matchStart = match.range.lowerBound
                let matchEnd = match.range.upperBound
                if let capturedName = match.output.1 {
                    let groupName = String(capturedName).trimmingCharacters(in: .whitespaces)
                    if matchStart > lastIndex {
                        addTextIfNonEmpty(String(text[lastIndex..<matchStart]), from: source)
                    }
                    closeCurrentGroup()
                    let ordinal = groupOrdinals[source.id, default: 0]
                    groupOrdinals[source.id] = ordinal + 1
                    currentGroup = ActiveResponseGroup(
                        id: "\(source.id)#group\(ordinal):\(groupName)",
                        name: groupName,
                        children: []
                    )
                } else {
                    if matchStart > lastIndex {
                        addTextIfNonEmpty(String(text[lastIndex..<matchStart]), from: source)
                    }
                    closeCurrentGroup()
                }
                lastIndex = matchEnd
            }
            if lastIndex < text.endIndex {
                addTextIfNonEmpty(String(text[lastIndex...]), from: source)
            }
        }

        private mutating func addBlock(_ block: ContentBlock) {
            guard block.type != .toolResult else { return }
            if currentGroup != nil {
                currentGroup?.children.append(block)
            } else {
                result.append(.contentBlock(block))
            }
        }

        private mutating func nextSegmentId(from source: ContentBlock) -> String {
            let index = segmentCounts[source.id, default: 0]
            segmentCounts[source.id] = index + 1
            return index == 0 ? source.id : "\(source.id)#seg\(index)"
        }

        private mutating func addTextIfNonEmpty(_ text: String, from source: ContentBlock) {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                addBlock(ContentBlock(
                    id: nextSegmentId(from: source),
                    type: .text,
                    text: trimmed
                ))
            }
        }

        private mutating func closeCurrentGroup() {
            if let group = currentGroup {
                result.append(.group(ResponseGroup(
                    id: group.id,
                    name: group.name,
                    children: group.children
                )))
                currentGroup = nil
            }
        }
    }
}

extension MessageView {
    static func plainTextContent(
        from blocks: [ContentBlock],
        hookWake: HookWakeAttribution? = nil,
        prWake: PrMonitorWakeAttribution? = nil
    ) -> String {
        MessageBlockPartitioning.plainTextContent(
            from: blocks,
            hookWake: hookWake,
            prWake: prWake
        )
    }

    static func userCopyText(
        from blocks: [ContentBlock],
        hookWake: HookWakeAttribution? = nil,
        prWake: PrMonitorWakeAttribution? = nil,
        agentMessage: AgentMessageAttribution? = nil
    ) -> String {
        MessageBlockPartitioning.userCopyText(
            from: blocks,
            hookWake: hookWake,
            prWake: prWake,
            agentMessage: agentMessage
        )
    }

    static func agentMessagePreview(
        from blocks: [ContentBlock],
        agentMessage: AgentMessageAttribution? = nil
    ) -> String {
        MessageBlockPartitioning.agentMessagePreview(from: blocks, agentMessage: agentMessage)
    }

    static func assistantCopyText(from blocks: [ContentBlock]) -> String {
        MessageBlockPartitioning.assistantCopyText(from: blocks)
    }

    static func partitionUserBlocks(
        _ blocks: [ContentBlock]
    ) -> UserBlockPartition {
        MessageBlockPartitioning.partitionUserBlocks(blocks)
    }

    static func groupContentBlocks(
        _ blocks: [ContentBlock],
        isStreaming: Bool = false
    ) -> [RenderBlock] {
        MessageBlockPartitioning.groupContentBlocks(blocks, isStreaming: isStreaming)
    }
}
