import MarkdownUI
import SwiftUI

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
        let markdownView = Markdown(text)
            .markdownTheme(MarkdownUI.Theme.compact)
            .markdownImageProvider(IntentFileImageProvider(workspaceId: workspaceId))
            .markdownInlineImageProvider(IntentFileInlineImageProvider(workspaceId: workspaceId))
            .markdownTextStyle(\.text) {
                ForegroundColor(Theme.foreground(for: colorScheme))
                FontSize(15)
            }
            .markdownTextStyle(\.link) {
                ForegroundColor(.blue)
            }
            .markdownTextStyle(\.code) {
                FontFamilyVariant(.monospaced)
                FontSize(.em(0.85))
                ForegroundColor(
                    colorScheme == .dark
                        ? Color(red: 0.9, green: 0.55, blue: 0.65)
                        : Color(red: 0.77, green: 0.1, blue: 0.3))
                BackgroundColor(
                    colorScheme == .dark
                        ? Color.white.opacity(0.1)
                        : Color.black.opacity(0.05))
            }
            .markdownBlockStyle(\.codeBlock) { configuration in
                configuration.label
                    .padding(12)
                    .background(Theme.muted(for: colorScheme).opacity(0.5))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .markdownTextStyle {
                        FontFamilyVariant(.monospaced)
                        FontSize(.em(0.85))
                    }
            }
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)

        if let handler = onOpenURL {
            markdownView
                .environment(\.openURL, OpenURLAction(handler: handler))
        } else {
            markdownView
        }
    }
}

