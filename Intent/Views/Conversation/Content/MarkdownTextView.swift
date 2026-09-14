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
    /// The window's session, when present: intent-file images then load over
    /// its backend connection rather than the shared (default) loader.
    @Environment(BackendSession.self) private var session: BackendSession?
    @State private var lightboxItem: LightboxItem?

    /// Intent-file image fetcher bound to the session's loader when one is in
    /// the environment, else the shared (default-backend) loader.
    private var fileImageFetcher: @Sendable (String, String) async throws -> UIImage {
        let fileLoader = session?.workspaceFileImageLoader ?? .shared
        return { workspaceId, path in
            try await fileLoader.image(workspaceId: workspaceId, path: path)
        }
    }

    var body: some View {
        let markdownView = StructuredText(markdown: Self.replacingTaskListMarkers(text))
            .textual.structuredTextStyle(.compact)
            .textual.imageAttachmentLoader(
                IntentFileAttachmentLoader(
                    workspaceId: workspaceId,
                    fallback: .image(),
                    fileImage: fileImageFetcher
                )
            )
            .textual.listItemSpacing(
                .fontScaled(
                    top: 2 / CompactMarkdownStyle.baseFontSize,
                    bottom: 4 / CompactMarkdownStyle.baseFontSize
                )
            )
            .textual.textSelection(.enabled)
            .textual.onAttachmentTap { attachment in
                if let image = Self.lightboxImage(for: attachment) {
                    lightboxItem = LightboxItem(image: image)
                }
            }
            .font(.body)
            .foregroundStyle(Theme.foreground(for: colorScheme))
            .frame(maxWidth: .infinity, alignment: .leading)
            .fullScreenCover(item: $lightboxItem) { item in
                ImageLightboxView(image: item.image)
            }

        if let handler = onOpenURL {
            markdownView
                .environment(\.openURL, OpenURLAction(handler: handler))
        } else {
            markdownView
        }
    }

    /// Routes attachment taps: only loaded markdown images (intent-file and
    /// remote http(s)) open the lightbox; every other attachment (e.g.
    /// failure placeholders) is inert.
    static func lightboxImage(for attachment: AnyAttachment) -> UIImage? {
        (attachment.base as? IntentFileImageAttachment)?.image
    }

    /// GFM task-list line: optional blockquote prefix, indent, list marker
    /// (bullet or ordered), then a `[ ]`/`[x]` marker.
    private static let taskListMarker =
        /^((?:[ \t]{0,3}>[ \t]?)*[ \t]*(?:[-*+]|[0-9]{1,9}[.)])[ \t]+)\[([ xX])\][ \t]+/

    /// Any list-item line (task or not), used to track list continuation so
    /// nested items indented 4+ columns are not mistaken for indented code.
    private static let listItemMarker =
        /^(?:[ \t]{0,3}>[ \t]?)*[ \t]*(?:[-*+]|[0-9]{1,9}[.)])[ \t]+\S/

    /// Textual's Markdown parser (Foundation's, cmark-based) has no task-list
    /// extension, so `- [ ]` / `- [x]` markers would render as literal
    /// brackets. Swap them for checkbox glyphs, skipping fenced and indented
    /// code blocks.
    static func replacingTaskListMarkers(_ text: String) -> String {
        guard text.contains("[") else { return text }
        var fenceMarker: Character?
        var inList = false
        return text.components(separatedBy: "\n")
            .map { line -> String in
                let indent = leadingIndentWidth(of: line)
                let trimmed = line.trimmingCharacters(in: .whitespaces)

                if let marker = fenceMarker {
                    if indent <= 3, trimmed.count >= 3, trimmed.allSatisfy({ $0 == marker }) {
                        fenceMarker = nil
                    }
                    return line
                }
                if indent <= 3 || inList {
                    if trimmed.hasPrefix("```") {
                        fenceMarker = "`"
                        return line
                    }
                    if trimmed.hasPrefix("~~~") {
                        fenceMarker = "~"
                        return line
                    }
                }
                if trimmed.isEmpty { return line }
                if indent >= 4, !inList { return line }

                if let match = line.prefixMatch(of: taskListMarker) {
                    inList = true
                    let box = match.output.2.lowercased() == "x" ? "☑" : "☐"
                    return "\(match.output.1)\(box) \(line[match.range.upperBound...])"
                }
                if line.prefixMatch(of: listItemMarker) != nil {
                    inList = true
                } else if indent < 2 {
                    inList = false
                }
                return line
            }
            .joined(separator: "\n")
    }

    /// Leading indentation in columns; a tab advances to the next multiple
    /// of 4, matching CommonMark's tab-stop rule.
    private static func leadingIndentWidth(of line: String) -> Int {
        var width = 0
        for char in line {
            if char == " " {
                width += 1
            } else if char == "\t" {
                width += 4 - width % 4
            } else {
                break
            }
        }
        return width
    }
}

/// Identifiable wrapper so a tapped attachment image can drive
/// `fullScreenCover(item:)`.
private struct LightboxItem: Identifiable {
    let id = UUID()
    let image: UIImage
}
