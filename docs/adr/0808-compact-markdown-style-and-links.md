# ADR-0808: Compact markdown style, link presentation and unopenable links

- Status: Accepted
- Recorded: 2026-11-20 (moved from code comments; the decisions are older)
- Applies to: `CompactMarkdownStyle`, `MarkdownLinkStyle`, `CompactHeadingStyle`, `CompactCodeBlockStyle`, `MermaidCodeBlockStyle`, `CompactTableStyle`, `CompactTableCellStyle`, `CompactTableCellLayout` (`Intent/Views/Conversation/Content/CompactMarkdownStyle.swift`), `StandaloneLinkRowView` (`Intent/Views/Conversation/Content/StandaloneLinkRowView.swift`), `UnopenableLink` (`Intent/Views/Conversation/Content/UnopenableLinkAlert.swift`), `ContextMentionChipView`, `ChipFlowLayout` (`Intent/Views/Conversation/Content/ContextMentionChipView.swift`)
- Related issues: #904

## Context

Markdown in the transcript, notes and pull requests uses one compact Textual
style. Links must read as links without the accent color, single-link lines
must be easy to tap, and a link the app cannot open must never fail silently.

## Decisions

### 1. The compact style ports the previous markdown theme

Applies to: `CompactMarkdownStyle`, `CompactCodeBlockStyle`, `CompactHeadingStyle`, `CompactTableCellStyle`

`CompactMarkdownStyle` is the Textual port of the app's previous compact
markdown theme: the same relative font scales, weights, margins and paddings,
expressed as a `StructuredText.Style`.

1. The inline-code colors come from the old `.markdownTextStyle(\.code)`
   override.
2. Inter has no monospaced design, so inline code and code blocks select the
   system code font explicitly.
3. `CompactCodeBlockStyle` is the old `.markdownBlockStyle(\.codeBlock)`
   override: 12 pt padding, a muted rounded box, monospaced 0.85 em, no
   horizontal scroller.
4. `CompactHeadingStyle` keeps the compact heading ratios and margins, with the
   Inter body baseline and real semibold and medium faces, rather than changing
   the prose scaling role.
5. `CompactTableCellStyle` uses Inter body cells, a semibold header row, and
   the existing 0.72 em / 0.35 em padding.

### 2. Links keep the text color and are underlined

Applies to: `CompactMarkdownStyle.inlineStyle`, `MarkdownLinkStyle`, `StandaloneLinkRowView`

Links keep the surrounding text color and read as links by underline (#904).
`MarkdownLinkStyle.plain` is for notes and pull requests. `.chat` is for
transcript messages, where single-link lines become full-width rows. Both keep
links underlined in the text color.

### 3. Single-link lines are full-width rows outside the selection overlay

Applies to: `StandaloneLinkRowView`, `StandaloneLinkRowView.Layout.bottomBlockSpacing`

A chat line that is only one link is drawn as a full-width row at least 44 pt
tall, so a tap anywhere on it opens the link, not only on the glyphs. It opens
through the environment's `openURL`, the same route as inline links. Title and
icons inherit the surrounding text color, like inline links (#904).

The row is wrapped in Textual's `Overflow`, which excludes it from Textual's
selection overlay. The overlay would otherwise take every tap and open only the
glyph run.

Block spacing collapses to the larger neighbor value. Rows stay close together,
and the row's own padding plus `bottomBlockSpacing` makes the gap before a
following paragraph equal to the paragraph spacing.

### 4. Mermaid diagrams and tables use Textual's overflow container

Applies to: `MermaidCodeBlockStyle`, `CompactTableStyle`, `CompactTableCellLayout`

1. A Mermaid diagram sits in `Overflow`, which excludes the region from the
   surrounding text-selection overlay.
2. `CompactTableStyle` keeps the GitHub grid decoration, but lets columns size
   independently of the transcript width. Textual's overflow container keeps
   selection gestures working.
3. `CompactTableCellLayout` measures and places with the same width proposal.
   Capping an already measured ideal-width cell would leave its wrapped text
   taller than the grid row.

### 5. A link the app cannot open shows an alert

Applies to: `UnopenableLink`, `UnopenableLink.Reason`, `UnopenableLink.reason(for:)`

A tapped link the app cannot open is shown in an alert with the link target
and a Copy Link action, so a link tap never silently does nothing.

1. `unsupportedLocation`: no scheme (a relative or absolute path), a `file://`
   link, or an app-internal scheme. iOS has nothing that opens it. A one-letter
   scheme is a Windows drive path such as `C:/Users/…`.
2. `unsupportedIntentLink`: an `intent://` link that is not a file, note, task,
   pairing or invite link. iOS would route it back to the app, which ignores
   it. Pairing and invite links are the only `intent://` links the app acts on
   when iOS hands them back (`AppCoordinator.handleIncomingURL`).
3. `browserFailed`: the in-app browser could not open a local server link.

`reason(for:)` returns nil when the URL can be handed to iOS. Callers route
workspace file and note links before they ask.

### 6. Context mention chips follow the web client

Applies to: `ContextMentionChipView`, `ContextMentionChipView.iconName(for:)`, `ChipFlowLayout`

`ContextMentionChipView` is the compact chip for an `@context[...]` mention in
a user message: a provider icon and the truncated decoded title on a muted
rounded background. It is the iOS counterpart of cloudlands-fe's
`ContextChip.svelte`. Chips whose `url` passes the `ExternalLink` http/https
allowlist open it in the browser. Chips without one, or with a rejected
scheme, are static. The title is cut at
`Constants.Conversation.ContextMention.titleMaximumLength` characters, where
the FE uses a CSS max width.

`iconName(for:)` follows the FE's provider-to-icon mapping: github to a
pull-request symbol, linear to a ticket, sentry to a bug, and browser,
external or unknown to a link.

`ChipFlowLayout` is a minimal leading-aligned wrapping layout for a run of
chips. It places subviews left to right at their ideal size and wraps to a new
line when the proposed width is exceeded.
