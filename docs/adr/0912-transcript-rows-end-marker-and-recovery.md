# ADR-0912: Transcript rows, end marker, and unrealized-end recovery

- Status: Accepted
- Recorded: 2026-11-20 (moved from code comments; the decisions are older)
- Applies to: `ConversationTranscriptView+Presentation.swift` (`Intent/Views/Conversation/Transcript/ConversationTranscriptView+Presentation.swift`): `transcriptRows(proxy:dividerAnchorId:)`, `transcriptEndRows(proxy:)`, `transcriptMessageRow(for:proxy:dividerAnchorId:generation:ownershipRevision:)`, `restorationMarker(for:)`, `preserveRowOffsetAfterDividerChange(messageId:measurement:proxy:)`; `ConversationTranscriptView+Recovery.swift` (`Intent/Views/Conversation/Transcript/ConversationTranscriptView+Recovery.swift`): `runUnrealizedEndRecovery(_:proxy:)`, `followBackAfterPageUp(_:proxy:)`, `recordUnrealizedEndRecoveryReport(outcome:cancelled:)`
- Related issues: #338, #737

## Context

The transcript rows live in a `LazyVStack`. The lazy stack can drop rows,
including the end row, and can realize no rows at all under an offset. The
end marker (`scroll-bottom`) tells the lifecycle whether the end is realized.

## Decisions

### 1. Row builders stay on the transcript

Applies to: `ConversationTranscriptView+Presentation.swift`

The row builders remain on `ConversationTranscriptView`, so the extraction
into an extension does not add an observation boundary or change the lazy
stack's row and anchor identities.

### 2. Rows are prepared on the main actor

Applies to: `transcriptRows(proxy:dividerAnchorId:)`,
`transcriptMessageRow(for:proxy:dividerAnchorId:generation:ownershipRevision:)`

Hydration, cached heights, and workspace inputs are snapshotted on the main
actor. SwiftUI may request the prepared row values on its render thread. The
prepared restoration marker is passed directly to `.overlay`, without a
render-thread closure capture (#737).

### 3. The tail and its footer are realized together

Applies to: `transcriptRows(proxy:dividerAnchorId:)`,
`ConversationTranscriptView.eagerTailMessageLimit`

The last `eagerTailMessageLimit` messages and the footer rows sit in one
`VStack` (`transcript-tail`). A separately lazy footer can stay absent at the
stack's estimated bottom after rows resize, even when repeated `scrollTo`
calls land.

### 4. Suggested prompts move to the composer on visionOS

Applies to: `transcriptEndRows(proxy:)`

On visionOS the composer renders suggested prompts as large chips above the
field (`MessageInputView`), so the transcript does not show them.

### 5. The end marker carries the bottom padding and the end-row signal

Applies to: `transcriptEndRows(proxy:)`

The stack's bottom padding lives on the `scroll-bottom` marker. So
`scrollTo("scroll-bottom", anchor: .bottom)` targets the true end of the
content, not a point 12 points (`bottomAnchorPadding`) above it that a landing
judged against `followLandingTolerance` could never reach.

The transcript keeps no launcher-tall padding under the last row. The
workspace action launcher floats over it, and follow landings still reach the
true end.

The marker's realization is the end-row signal that the unrealized-end
recovery reads (#338). The lazy stack shows and hides the marker as it
realizes and drops it. Realizing while scrolled away replays the live edge.
Derealizing arms the recovery.

While a demo has withdrawn the marker (see `withdrawEndRowForDemo`), a
stand-in of the same height takes its place. The content height and every
offset the recovery reads are unchanged, but the stand-in has no id and no
realization handlers. `scrollTo("scroll-bottom")` finds nothing and
`isEndRealized` stays false, exactly as over a dropped end row.

### 6. One stable lazy-stack target per message

Applies to: `transcriptMessageRow(for:proxy:dividerAnchorId:generation:ownershipRevision:)`,
`restorationMarker(for:)`

Each message is one stable lazy-stack target. A late divider changes the
row's height without shifting the identity of all following rows.

A realized row's top marker lets SwiftUI own the final retained offset, even
for partial or viewport-sized rows, without taking layout space.

### 7. Divider changes preserve the row offset

Applies to: `preserveRowOffsetAfterDividerChange(messageId:measurement:proxy:)`

The live `retainViewportMessages` check also covers a queued callback that
beats the column's message-ID observer after an authoritative deletion. The
geometry callback includes the divider identity, so even a row that bottom
anchoring already holds consumes this revision without moving.

### 8. Unrealized-end recovery (#338)

Applies to: `runUnrealizedEndRecovery(_:proxy:)`,
`ConversationTranscriptScrollPolicy.unrealizedEndRecoveryStep`

Once the geometry has settled, the recovery verifies that a following viewport
rests on realized rows, and recovers a blank one. The lazy stack can realize no
rows at all under an offset that still reads "at bottom". The container
re-pin's `scrollTo` after a footer row landed did exactly that on a transcript
whose last rows re-measure. So every geometry-driven path stays silent.

1. The lifecycle arms the recovery when the end row derealizes, or when a
   follow drains with the end row still unrealized (the row it cancelled the
   recovery over yields no new edge).
2. Corrections search progressively above prior attempts so rows realize, then
   follow back to the end. The loop verifies again from two fresh reads, a
   bounded number of times.
3. The loop keeps the deadline and the correction budget, and reports each
   step and its terminal to the lifecycle under its token. The lifecycle
   decides what the step may do: a gesture or a follow in flight is waited
   out; a user who rests away ends it; a gesture or a follow that claims the
   viewport while a correction has it paged up cancels it. The follow back
   checks the claim again once the rows have realized, rather than scrolling
   over it.
4. A correction in flight owns the viewport as a follow does. So the growth
   re-pin stays suppressed until the terminal replays the live edge. Once the
   budget is spent over a still-unrealized row, it shows Go to End rather than
   scroll blind, deferring that to the follow that owns the viewport if there
   is one.
5. The recovery is not a forced follow, so the follow's report is left as it
   is. The recovery reports next to it under `--demo-data`.
6. A verification that is already running keeps its budget. It reads the end
   row's current state at every poll, so re-arming it would only reset the
   bound.

### 9. Follow back after a page up

Applies to: `followBackAfterPageUp(_:proxy:)`

The step read the live geometry in the same pass, so the page up found the
scroll view. The rows realize under the paged-up offset before the follow back
checks the claim again. The function returns false when the loop ends there:
cancelled during the settle, or yielded to the user.

### 10. Every recovery terminal is observable

Applies to: `recordUnrealizedEndRecoveryReport(outcome:cancelled:)`

The report records how the episode ended, the corrections it spent, and the
end row's realization at that moment. So every terminal path (resolved on any
terminal, or cancelled) is observable under `--demo-data` (see
`ConversationTranscriptScrollPolicy.unrealizedEndRecoveryReport`).
