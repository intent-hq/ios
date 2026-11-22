# ADR-0132: Transcript entry scroll and retained viewport

- Status: Accepted
- Recorded: 2026-11-20 (moved from code comments; the decisions are older)
- Applies to: `ConversationTranscriptView+EntryScroll.swift` (`Intent/Views/Conversation/Transcript/ConversationTranscriptView+EntryScroll.swift`): `restoreRetainedViewport(proxy:)`, `handleMessageCountChange(from:to:proxy:)`, `runInitialScrollIfNeeded(proxy:)`, `performInitialScrollWhenReady(proxy:scrollViewWaitElapsed:generation:)`, `performInitialScroll(proxy:generation:)`

## Context

When a conversation opens, the transcript scrolls once: to the unread divider
when there is one, else to the end. A transcript that was visible before can
restore its retained viewport instead. Both depend on the lazy stack and the
`UIScrollView` being ready.

## Decisions

### 1. Retained viewports realize the tail before the row

Applies to: `restoreRetainedViewport(proxy:)`

A nested message ID cannot reliably realize its offscreen lazy parent. When
the target is among the eager tail messages, the transcript scrolls to
`transcript-tail` first and then resolves the row.

### 2. An emptied transcript re-arms the entry scroll

Applies to: `handleMessageCountChange(from:to:proxy:)`

The lifecycle and its tasks live in the parent-owned scroll state, so they
survive the empty view that replaces this transcript. The `.rearmEntryScroll`
path reuses the all-owner cancellation (`cancelPendingFollowOnTakeover`)
before it resets the entry latches. The reset clears its gesture-specific
fallback state.

### 3. The entry decision is taken at initial layout

Applies to: `runInitialScrollIfNeeded(proxy:)`

The entry scroll runs exactly once per transcript lifetime, from whichever
loading trigger fires first. Snapshot appearance can come a layout pass before
an already-running detail read. So the decision is taken at initial layout,
not at the scheduling edge.

### 4. The entry scroll waits for hosting, with a bound

Applies to: `performInitialScrollWhenReady(proxy:scrollViewWaitElapsed:generation:)`

A `scrollTo` issued before the `UIScrollView` is hosted is lost, and the
bottom anchor wins. So when the entry timer beats hosting (an instant load
during the push transition), the scroll waits for the finder's edge. The wait
is bounded by `initialScrollHostingTimeout`, so a finder that never resolves
still scrolls. The entry scroll is performed at most once across all paths.

### 5. Entry scroll targets

Applies to: `performInitialScroll(proxy:generation:)`

1. Without an unread divider, the entry scroll is a forced follow, so its
   landing is verified from the live geometry like any other follow.
2. The divider is nested inside a stable lazy row. The transcript first
   realizes the row's bottom, including when the seen message is taller than
   the viewport. The divider's measured frame then aligns the boundary at the
   top.
3. The divider probe runs before `hasInitiallyScrolled` flips, because
   `dividerProbeDelay` is shorter than `initialScrollSettleDelay`. So no
   automatic follow can be queued ahead of this decision.

### 6. Short transcripts stay bottom-aligned

Applies to: `ConversationTranscriptView` (`.frame(minHeight: viewportContentHeight, alignment: .bottom)`)

The transcript content has a minimum height equal to the viewport and aligns to
the bottom. A transcript shorter than the screen then stays against the
composer when the keyboard changes the viewport, instead of jumping to the top.
