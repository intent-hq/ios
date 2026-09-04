import Foundation

enum MessageBlockPartitioning {
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
                let plain = ContextMention.replacingTokensWithTitles(
                    in: stripSupervisorTags(text))
                return plain.isEmpty ? nil : plain
            case .code:
                return block.resolvedText
            default:
                return nil
            }
        }.joined(separator: "\n\n")
    }

    static func userCopyText(
        from blocks: [ContentBlock],
        hookWake: HookWakeAttribution? = nil,
        prWake: PrMonitorWakeAttribution? = nil
    ) -> String {
        plainTextContent(
            from: partitionUserBlocks(blocks).text,
            hookWake: hookWake,
            prWake: prWake)
    }

    static func agentMessagePreview(from blocks: [ContentBlock]) -> String {
        userCopyText(from: blocks)
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
        }.joined(separator: "\n\n")
    }

    static func stripSupervisorTags(_ text: String) -> String {
        text.replacingOccurrences(
            of: "<supervisor>[\\s\\S]*?</supervisor>",
            with: "",
            options: .regularExpression
        ).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func partitionUserBlocks(
        _ blocks: [ContentBlock]
    ) -> (text: [ContentBlock], images: [ContentBlock], files: [ContentBlock]) {
        (blocks.filter { $0.type == .text },
         blocks.filter { $0.type == .image },
         blocks.filter { $0.type == .file })
    }

    private static let groupTagRegex = #/<group:([^>\r\n<]+)>|<\/group(:[^>\r\n<]+)?>/#
    private static let incompleteGroupTagRegex = #/<\/?g(?:r(?:o(?:u(?:p(?::?[^>\r\n<]*)?)?)?)?)?$/#

    static func groupContentBlocks(
        _ blocks: [ContentBlock],
        isStreaming: Bool = false
    ) -> [RenderBlock] {
        var result: [RenderBlock] = []
        var currentGroup: (id: String, name: String, children: [ContentBlock])?
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
            return index == 0 ? source.id : "\(source.id)#seg\(index)"
        }

        func addTextIfNonEmpty(_ text: String, from source: ContentBlock) {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                addBlock(ContentBlock(
                    id: nextSegmentId(from: source), type: .text, text: trimmed))
            }
        }

        func closeCurrentGroup() {
            if let group = currentGroup {
                result.append(.group(ResponseGroup(
                    id: group.id, name: group.name, children: group.children)))
                currentGroup = nil
            }
        }

        for block in blocks {
            guard block.type == .text,
                  let blockText = block.resolvedText,
                  !blockText.isEmpty else {
                if block.type != .text { addBlock(block) }
                continue
            }

            var processedText = blockText
            if isStreaming {
                processedText = processedText.replacing(incompleteGroupTagRegex, with: "")
                if processedText.isEmpty { continue }
            }

            let matches = processedText.matches(of: groupTagRegex)
            if matches.isEmpty {
                if processedText == blockText {
                    addBlock(block)
                } else {
                    addBlock(ContentBlock(
                        id: nextSegmentId(from: block), type: .text, text: processedText))
                }
                continue
            }

            var lastIndex = processedText.startIndex
            for match in matches {
                let matchStart = match.range.lowerBound
                let matchEnd = match.range.upperBound

                if let capturedName = match.output.1 {
                    let groupName = String(capturedName)
                        .trimmingCharacters(in: .whitespaces)
                    if matchStart > lastIndex {
                        addTextIfNonEmpty(
                            String(processedText[lastIndex..<matchStart]), from: block)
                    }
                    closeCurrentGroup()
                    let ordinal = groupOrdinals[block.id, default: 0]
                    groupOrdinals[block.id] = ordinal + 1
                    currentGroup = (
                        id: "\(block.id)#group\(ordinal):\(groupName)",
                        name: groupName,
                        children: [])
                } else {
                    if matchStart > lastIndex {
                        addTextIfNonEmpty(
                            String(processedText[lastIndex..<matchStart]), from: block)
                    }
                    closeCurrentGroup()
                }
                lastIndex = matchEnd
            }

            if lastIndex < processedText.endIndex {
                addTextIfNonEmpty(String(processedText[lastIndex...]), from: block)
            }
        }

        closeCurrentGroup()
        return result
    }
}

extension MessageView {
    static func plainTextContent(
        from blocks: [ContentBlock],
        hookWake: HookWakeAttribution? = nil,
        prWake: PrMonitorWakeAttribution? = nil
    ) -> String {
        MessageBlockPartitioning.plainTextContent(
            from: blocks, hookWake: hookWake, prWake: prWake)
    }

    static func userCopyText(
        from blocks: [ContentBlock],
        hookWake: HookWakeAttribution? = nil,
        prWake: PrMonitorWakeAttribution? = nil
    ) -> String {
        MessageBlockPartitioning.userCopyText(
            from: blocks, hookWake: hookWake, prWake: prWake)
    }

    static func agentMessagePreview(from blocks: [ContentBlock]) -> String {
        MessageBlockPartitioning.agentMessagePreview(from: blocks)
    }

    static func assistantCopyText(from blocks: [ContentBlock]) -> String {
        MessageBlockPartitioning.assistantCopyText(from: blocks)
    }

    static func partitionUserBlocks(
        _ blocks: [ContentBlock]
    ) -> (text: [ContentBlock], images: [ContentBlock], files: [ContentBlock]) {
        MessageBlockPartitioning.partitionUserBlocks(blocks)
    }

    static func groupContentBlocks(
        _ blocks: [ContentBlock],
        isStreaming: Bool = false
    ) -> [RenderBlock] {
        MessageBlockPartitioning.groupContentBlocks(blocks, isStreaming: isStreaming)
    }
}