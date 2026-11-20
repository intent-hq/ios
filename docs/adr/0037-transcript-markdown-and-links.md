# 0037. Transcript Markdown and links

**Status:** Accepted (recorded 2026-11-20 from code comments)

## Context

Assistant text is Markdown rendered by Textual. Agents write links to workspace files, notes, pull requests, local servers, and paths that iOS cannot open. Each row has a text-selection and Copy overlay that takes taps. [ADR 0064](0064-markdown-parse-caches-and-link-rows.md) covers the parse caches and how link rows are detected; [ADR 0081](0081-links-from-agents-and-daemons.md) covers link parsing and the web allowlist.

## Decision

1. **Link look.** Links keep the surrounding text color and read as links by their underline, not by the accent tint (#904). `MarkdownTextView` sets the tint to the text color, because SwiftUI draws link runs in the tint. `MarkdownLinkStyle.plain` serves notes and pull requests; `.chat` serves transcript messages, where a line that is only one link becomes a full-width row.
2. **Standalone link rows.** `StandaloneLinkRowView` is at least 44 pt tall, so a tap anywhere on it opens the link, not just on the glyphs. It opens through the environment's `openURL`, like inline links. It sits in an `Overflow`, which takes it out of Textual's selection overlay; otherwise the overlay takes every tap and opens only the glyph run.
3. **Wide content.** Code blocks and tables sit in an `Overflow`, which keeps selection gestures and takes them out of the surrounding selection overlay. Table columns size independently of the transcript width. `CompactTableCellLayout` measures and places with the same width proposal, because capping an already measured cell would leave its wrapped text taller than the grid row.
4. **Link routing (`textURLRoute(for:workspaceId:)`).** One route serves transcript Markdown and the Assistant workspace's linked text. Workspace file links open in the matching viewer, written either as `intent://local/file/…` or as a path (`report.html`, `/…/report.html`, `file://…`). Other links go to the inherited `openURL` handler, which opens tracked pull requests in the app.
5. **Unopenable links.** A link tap never does nothing silently. `UnopenableLink.reason(for:)` returns a reason, and an alert shows the target with Copy Link.
   1. No scheme, `file://`, an app-internal scheme, or a one-letter scheme (a Windows drive path such as `C:/Users/…`) is `unsupportedLocation`.
   2. An `intent://` link that is not a file, note, task, pairing or invite link is `unsupportedIntentLink`. iOS would hand it back to the app, and only `pair` and `invite` act there (`AppCoordinator.handleIncomingURL`).
6. **Display text.** `stripSuggestedPrompts(_:)` removes suggested-prompts blocks, HTML comments, `<agent_digest>` and supervisor tags. Whole-message copy uses the same function, so copied text matches rendered text.
   1. Only well-formed suggested-prompts blocks are removed (`SuggestedPrompts`). Body text that only looks like one stays.
   2. The HTML-comment pass skips suggested-prompts openers, so a malformed opener cannot capture body text up to an embedded `-->`, such as a Mermaid edge.
7. **Task lists.** Textual's parser (Foundation, cmark-based) has no task-list extension. `replacingTaskListMarkers(_:)` swaps `[ ]` and `[x]` for checkbox glyphs, and skips fenced and indented code. It tracks list continuation, so a nested item indented four or more columns is not read as indented code. A tab advances to the next multiple of 4, the CommonMark tab stop.
8. **User text.** User messages parse inline Markdown only (`userDisplayText(_:)`), so typed line breaks and list markers stay as written. Links follow the same look as replies (#904).
9. **Context mentions.** `ContextMentionChipView` matches the desktop `ContextChip`. A chip opens its `url` only when it passes the `ExternalLink` allowlist; otherwise it is static. The title is cut at about 30 characters (the desktop uses a CSS max width). The icon follows the desktop provider map: GitHub, Linear, Sentry, and a link icon for the rest.

## Consequences

- A tappable element inside transcript text must sit in an `Overflow` or use Textual's own link handling, or the selection overlay takes the tap.

## Code

- `CompactMarkdownStyle`, `MarkdownLinkStyle`, `CompactCodeBlockStyle`, `CompactTableStyle`, `CompactTableCellLayout`
- `MarkdownTextView`: `replacingTaskListMarkers(_:)`
- `StandaloneLinkRowView`
- `ContentBlockView`: `textURLRoute(for:workspaceId:)`, `TextURLRoute`, `stripSuggestedPrompts(_:)`
- `UnopenableLink`: `reason(for:)`, `unopenableLinkAlert(_:)`
- `ContextMentionChipView`: `displayTitle(_:)`, `iconName(for:)`
- `UserMessageView`: `userDisplayText(_:)`
