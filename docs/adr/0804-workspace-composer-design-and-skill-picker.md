# ADR-0804: The workspace composer design is presentation only; the skill picker memoizes its ranking

- Status: Accepted
- Recorded: 2026-11-20 (moved from code comments; the decisions are older)
- Applies to: `WorkspaceComposerRow`, `WorkspaceComposerSurface` (`Intent/Views/Conversation/Composer/WorkspaceComposerRow.swift`), `WorkspaceQueuedMessagesView`, `WorkspaceQueuePanel` (`Intent/Views/Conversation/Composer/WorkspaceQueuedMessagesView.swift`), `SkillSuggestionsView` (`Intent/Views/Conversation/Composer/SkillSuggestionsView.swift`), `ComposerSkillCompletion` (`Intent/Views/Conversation/Composer/ComposerSkillCompletion.swift`)

## Context

The workspace design restyles the composer and the message queue. The slash
command skill picker ranks the skill catalog against the typed query on every
render.

## Decisions

### 1. Workspace composer views only present; the owner keeps behavior

Applies to: `WorkspaceComposerRow`, `WorkspaceQueuedMessagesView`, `WorkspaceQueuePanel`

`WorkspaceComposerRow` is a workspace-only presentation. The owner keeps draft,
attachment and send behavior. `WorkspaceQueuedMessagesView` is a workspace-only
queue presentation; its commands still belong to the conversation owner.
`WorkspaceQueuePanel` wraps the existing composer without changing the
composer's identity as the queue appears and disappears.

### 2. Workspace composer metrics

Applies to: `WorkspaceComposerRow.editorInset`, `WorkspaceComposerSurface`, `WorkspaceQueuedMessagesView` (queue row actions)

1. UITextView's existing container inset and default line-fragment padding
   together make up the reference design's 20 pt text inset.
2. `WorkspaceComposerSurface` is the shared shape for the composer row and any
   pending attachment rows above it.
3. Queue row actions keep the reference design's glyph spacing while each
   action gets a non-overlapping 44 pt hit region. Negative padding of
   `Layout.controlInset` offsets the larger hit region, and the surrounding
   gaps absorb the inset.

### 3. Skill picker presentation

Applies to: `SkillSuggestionsView`, `SkillSuggestionsView.skillPreview(_:)`

The slash-command skill picker is a horizontally scrolling row of chips above
the composer. The highlighted chip uses the accent. Return or a tap inserts it.
A chip shows only the skill name; a long press shows the preview with the
description.

### 4. Skill ranking is memoized but stays observed

Applies to: `ComposerSkillCompletion.matches`, `ComposerSkillCompletion.rankingCount`

Reading `catalog.skills` and `context` in `matches` keeps observers subscribed
to both inputs. The ranked result is memoized, so repeated reads within one
render do not re-rank the catalog. `rankingCount` counts how many times the
catalog was ranked; reads between query or catalog changes reuse the result.
