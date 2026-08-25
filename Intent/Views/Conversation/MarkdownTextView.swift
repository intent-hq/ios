import SwiftUI
import Textual

struct MarkdownTextView: View {
    let text: String
    /// Optional handler for URL taps. Return `.handled` to prevent default behavior.
    var onOpenURL: ((URL) -> OpenURLAction.Result)?
    /// Workspace resolving short-form `intent://local/file/<path>` image links.
    /// Intent-file images render even when nil if the link carries its own
    /// workspace ID (long form).
    var workspaceId: String?
    @Environment(\.colorScheme) var colorScheme

    var body: some View {
        let markdownView = StructuredText(markdown: Self.replacingTaskListMarkers(text))
            .textual.structuredTextStyle(.compact)
            .textual.imageAttachmentLoader(
                IntentFileAttachmentLoader(workspaceId: workspaceId, fallback: .image())
            )
            .textual.listItemSpacing(
                .fontScaled(
                    top: 2 / CompactMarkdownStyle.baseFontSize,
                    bottom: 4 / CompactMarkdownStyle.baseFontSize)
            )
            .textual.textSelection(.enabled)
            .font(.system(size: CompactMarkdownStyle.baseFontSize))
            .foregroundStyle(Theme.foreground(for: colorScheme))
            .frame(maxWidth: .infinity, alignment: .leading)

        if let handler = onOpenURL {
            markdownView
                .environment(\.openURL, OpenURLAction(handler: handler))
        } else {
            markdownView
        }
    }

    /// GFM task-list line: optional indent, bullet, then a `[ ]`/`[x]` marker.
    private static let taskListMarker = /^([ \t]*[-*+][ \t]+)\[([ xX])\][ \t]+/

    /// Textual's Markdown parser (Foundation's, cmark-based) has no task-list
    /// extension, so `- [ ]` / `- [x]` markers would render as literal
    /// brackets. Swap them for checkbox glyphs, skipping fenced code blocks.
    static func replacingTaskListMarkers(_ text: String) -> String {
        guard text.contains("[") else { return text }
        var inFence = false
        return text.components(separatedBy: "\n").map { line -> String in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                inFence.toggle()
                return line
            }
            guard !inFence, let match = line.prefixMatch(of: taskListMarker) else {
                return line
            }
            let box = match.output.2.lowercased() == "x" ? "☑" : "☐"
            return "\(match.output.1)\(box) \(line[match.range.upperBound...])"
        }.joined(separator: "\n")
    }
}

