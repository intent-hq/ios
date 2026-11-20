# ADR-1311: Conversation design constants and the readable column

- Status: Accepted
- Recorded: 2026-11-20 (moved from code comments; the decisions are older)
- Applies to: `Constants.Conversation.Design` (`Intent/DesignSystem/ConversationDesign.swift`),
  `Constants.Conversation.Design.Palette` (`Intent/DesignSystem/ConversationDesignColors.swift`),
  `Constants.Conversation.ImagePlaceholder`, `Constants.Conversation.ImageThumbnail`
  (`Intent/DesignSystem/ConversationMediaLayout.swift`),
  `conversationReadableColumn()`, `iPadDetailColumn(isEnabled:)`, `ConversationReadableColumn`
  (`Intent/DesignSystem/ConversationReadableColumn.swift`),
  `Constants.Conversation.StatusStrip.BackgroundHooks` (`Intent/DesignSystem/ConversationTranscriptLayout.swift`),
  `Constants.Markdown`, `Constants.TableCell` (`Intent/DesignSystem/MarkdownLayout.swift`)

## Context

The workspace-agent and Assistant conversation screens share one styling from
the approved Figma frames. These decisions explain values that do not speak for
themselves.

## Decisions

### 1. Shared styling is opt-in on iPad and keeps native text behavior

Applies to: `Constants.Conversation.Design`

The design is the shared iOS workspace-agent and Assistant styling from the
approved Figma frames. iPad opts in explicitly; standard regular-width and
visionOS callers stay unchanged. Heights are visual baselines, not text caps:
preserve Dynamic Type and platform hit targets.

### 2. Specific values

- `IPad.conversationMaximumWidth`: the chat fills the panel, as in portrait,
  until lines get too long to scan.
- `Column.transcriptHeightFraction`: reserve a usable transcript band from the
  native keyboard-safe column. The remaining space, minus measured footer
  content, belongs to questions.
- `Transcript.bubbleMaximumWidthFraction`: an adaptive implementation policy;
  accessibility text uses the full available width.
- `Composer.verticalBarBottomSpacing`: the Duo's 48 pt launcher sits 24 pt from
  the screen bottom: 24 + (48 - 56) / 2.
- `Composer.stopSide`: Figma's stop control is a rounded rectangle, not the
  larger bundled `StopFill` glyph.
- `Question.titleSpacing`: native line boxes include leading that Figma trims;
  the value preserves the visible text gap.
- `Typography`: Figma tracking is a percent of point size: Body S -1%, compact
  body and XS -2%. Reuse `Constants.Typography.bodyS`, `bodySEmphasized`,
  `bodyXS` and `bodyXSEmphasized` through `interFont`. Do not impose Figma's
  trimmed line-box heights on native text layout.

### 3. The conversation palette reuses shipping colors

Applies to: `Constants.Conversation.Design.Palette`

The palette is conversation-only. It reuses the already-shipping neutral and
yellow Figma colors from Pairing and Theme's white surface without changing
either existing palette. Exact sRGB values come from full-frame modes
3020:36994 / 3016:35726, answer cards 3223:18416 / 3223:19376 and blockers
3198:12684 / 3198:11702; exact 8-bit channels and alpha keep direct comparison
with those exports. `surface(for:)` is used by user bubbles, the composer, the
monitoring strip and the question shell. `raisedSurface(for:)` is for selected
answers and secondary question actions, which sit above the shell.

### 4. Media sizes are shared

Applies to: `ImagePlaceholder.failureLabelSpacing`, `ImageThumbnail.transcriptSide`

`failureLabelSpacing` is shared by the failure view and Textual's intrinsic-size
calculation. Assistant image blocks and Markdown images share the 160 pt square
`transcriptSide`.

### 5. The readable column

Applies to: `conversationReadableColumn()`, `iPadDetailColumn(isEnabled:)`,
`ConversationReadableColumn`

`conversationReadableColumn()` constrains the transcript and composer; navigation
stays outside this column. `iPadDetailColumn` counts the page inset outside the
readable body, because detail children already own their page inset. The Duo
keeps the narrow column: a closed drawer spans the chat across the fold. The
modifier keeps one structural identity as the window or sidebar changes size.

### 6. Other values

- `StatusStrip.BackgroundHooks.nameMaxLength`: the maximum characters of a hook
  name shown on a chip, mirroring the FE's visual max-width truncation.
- `Markdown.baseFontSize`: the default `.body` size, used to convert the compact
  theme's em margins.
- `TableCell.maximumWidth`: bounds descriptive text without squeezing columns to
  the viewport.
