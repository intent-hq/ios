# 0038. Transcript rows, scroll hosting and conversation chrome

**Status:** Accepted (recorded 2026-11-20 from code comments)

## Context

The transcript is a SwiftUI lazy stack in a `ScrollView`. [ADR 0060](0060-transcript-pin-follow-takeover.md) and [ADR 0061](0061-transcript-viewport-ownership-and-recovery.md) decide when it follows, re-pins and recovers. This record covers how the view is built so those rules can work: which rows are realized together, how the UIScrollView is found, how rows avoid extra renders while a reply streams, and how the conversation screen around it behaves.

## Decision

1. **One scroll-state machine.** `ConversationTranscriptView` keeps the ordered observation wiring in its body. Presentation, entry, follow, recovery, geometry and demo code live in extensions that add no view identity, observation boundary or state owner. The extensions read `scrollState` through read-only conveniences; mutations target the parent-owned `scrollState`. The scroll modifier chain stays one function, because splitting it would hide the order of gesture, geometry and past-end observations.
2. **Finding the UIScrollView.**
   1. `ScrollViewFinder` sits on the stack itself, not on a lazily realized row, so it is found whatever rows exist.
   2. It walks up the view hierarchy from `didMoveToWindow`, not from `makeUIView`. At creation it has no window, and the walk stops one hop up. A re-attach runs the walk again.
   3. `hasResolvedScrollView` is a sticky "was hosted" edge, not a liveness signal. Weak zeroing skips `didSet`, so it stays true after the scroll view goes away.
   4. Keyboard dismissal is a `UITapGestureRecognizer` on the UIScrollView (`KeyboardDismissTapGesture`), not a SwiftUI tap gesture, which would starve Textual's UIKit link taps. It resigns on the next run-loop turn, so child image and link taps resolve before the keyboard moves their layout.
3. **Realization targets.**
   1. A bounded tail and its footer realize together in one `VStack` (`transcript-tail`). A separately lazy footer can stay absent at the estimated bottom after rows resize, even when repeated `scrollTo` calls land.
   2. The `scroll-bottom` marker carries the stack's bottom padding, so `scrollTo("scroll-bottom", anchor: .bottom)` targets the true end of the content. Its realization is the end-row signal for recovery (#338).
   3. A follow targets `scroll-bottom` when the end row is realized, otherwise `transcript-tail`; both end at the footer.
   4. Each message is one stable lazy-stack target. A late new-messages divider lives inside that row, so it changes the row's height without shifting the identity of the rows after it. A zero-height top marker per row lets SwiftUI own the final retained offset, also for partial or viewport-sized rows.
   5. A nested message id cannot reliably realize its offscreen lazy parent. The entry scroll realizes the tail first, then the row. For a divider, it realizes the row's bottom first, then aligns the divider at the top by its measured frame. The divider probe runs before `hasInitiallyScrolled` flips, so no automatic follow can queue ahead of that decision.
   6. A snapshot can appear a layout pass before a detail read that is already running. The entry scroll decides at initial layout, not when it is scheduled.
   7. The scroll lifecycle and its tasks live in the parent-owned scroll state, so they survive the empty view replacing the transcript.
4. **History.**
   1. Position preservation for an older page runs synchronously when the page is accepted, before observable rows change. Request-time frames can be stale; post-await frames can already include the new rows.
   2. After a prepend, the view waits for layout and retained-position restoration before it measures the new top. A prepend can leave the reader in the prefetch band without a new edge, and a fast reply could otherwise load pages against old frames.
   3. A history prepend's coarse restoration can briefly cross the bottom band. That is not a user returning to the tail (#711), so the reading position is kept until the page settles. Gestures and explicit follows still take over at once.
5. **Distance.** `containerSize` leaves out safe-area insets but `contentOffset` includes them. The distance to the bottom uses `visibleRect`, which spans the full bounds like UIScrollView.
6. **Render cost while streaming.** `MessageView`, `ResponseGroupView` and `AssistantMessageView` are thin shells over `.equatable()` bodies. A row re-renders only when its message, workspace, paired tool results or hydration set changes. The manual `==` leaves out closures on purpose: the parent builds new ones on each evaluation, and they capture only stable ids. Per-group inputs are narrowed to the group's own children. `AssistantMessageView` and `UserMessageView` derive render blocks, pairings, attributions and copy text once per message value in `init`. `ResponseGroup` ids are deterministic from the source (opening block id, ordinal, name), so a streaming delta does not reset a group's expansion. A message whose streamed suggested-prompts block closes rebuilds its cached Markdown (`.id(hasStrippedPrompts)`). A slim-truncated tool row fetches its full bodies when it expands.
7. **Logging and diagnostics.** Keyboard geometry logs read only the geometry and timing keys, never the whole notification payload. Scroll-geometry traces never include conversation content or backend ids and do no work in Release. Demo-only diagnostics (`TranscriptGestureAccessibilityView`, the transcript probe overlay, `DemoRecoveryResize`) are sampled when XCTest queries them, never cached in a SwiftUI body, never feed a recovery decision and never change recovery timing.
8. **Conversation screen.**
   1. `ConversationView` keeps its modifier layers in order (column, chrome, presentation, lifecycle). The column keeps its identity, and so its scroll state, across width changes.
   2. Entry never marks the conversation seen. The unread divider stays until the user leaves or the turn finishes.
   3. A failed image or file placement restores the draft and keeps the pending attachments (monorepo#3338). A failed dismissal keeps the error text stable while the wizard restores its pending marker (monorepo#1800).
   4. When the agent no longer exists (not found at load, or deleted elsewhere), the screen goes back to the workspace's agent list. A delete started on this screen already dismisses it.
   5. `ConversationNoteSheet` pushes a note-to-note link that targets the hidden Assistant workspace inside the sheet. That workspace has no place in the Workspaces tab, so the coordinator route would replace the user's open workspace. Other links use the coordinator route.
   6. On iPad, while the inline wizard holds the composer slot, PR monitors and queued-message actions stay reachable above it. Script watch details stay mounted outside the composer and question slot.
   7. `ConversationBackground` belongs to the screen, outside its top safe-area inset. On visionOS the navigation bar draws no background, so a material band behind it blurs the rows under it (`ConversationHeaderBackdrop`). The column measures its height inside keyboard avoidance, so caps use the remaining visible height.
9. **Workspace design.**
   1. The workspace transcript design is opt-in at the approved root only (`workspaceTranscriptDesign`); shared callers keep their UI.
   2. In the Duo shell the rail replaces the vertical toolbar, so the navigation bar is hidden there. The iPad shell names the workspace and the open agent in its sidebar, so the header shows them only while the sidebar is collapsed. An overview header with no copy collapses on the rail instead of leaving an empty band.
   3. Header controls reserve only the system's real corner region (`containerCornerOffset`), including iPad window controls. Header and bubble text measure from cap top to final baseline without clipping glyphs (`WorkspaceTextTrimLayout`, `WorkspaceUserBubbleLayout`), with no fixed heights or screen-size reads.

## Consequences

- A new footer row must be inside the tail `VStack`, or follows can stop short of it.
- A new row type must keep closures out of its equatable body.
- Render block ids are deterministic (`groupContentBlocks`): a synthetic segment id is the source block id plus the segment index, and a group id is the block id plus a per-block ordinal plus the name. Re-parsing the same input gives the same ids. A still-open group and the later closed group get the same id from the opening tag, the first segment reuses the source block id, and a block without tags keeps its raw id when a tag streams into it, so streaming never tears down a rendered row's view state (from test comments).
- A user row renders text first, then image and video attachments as thumbnails, then file attachments as chips, whatever the block order in the payload (`MessageBlockPartitioning.partitionUserBlocks`) (from test comments).
- `pairToolResults(_:)` runs once per message over the whole raw block list, not per render row. Each block row's equatable gate then compares only its own tool result, and a `tool_use` inside a group still finds a `tool_result` that lands after the closing tag (from test comments).

## Code

- `ConversationTranscriptView`: `transcriptScrollView(…)`, `ScrolledAwayGeometry`, `userIsScrolledAway`
- `ScrollViewFinder`, `ScrollViewMomentumProxy`: `hasResolvedScrollView`; `KeyboardDismissTapGesture`
- `ConversationTranscriptView` extensions: `performInitialScroll(proxy:generation:)`, `restoreRetainedViewport(proxy:)`, `preserveHistoryPosition()`, `applyScrolledAwayEdge(geometryAway:proxy:)`, `logKeyboardGeometry(_:notification:)`, `logScrollGeometry(_:)`
- `MessageView`, `MessageRowContent`, `ResponseGroupView`, `ResponseGroupBody`, `ResponseGroup`, `AssistantMessageView`, `UserMessageView`, `ToolCallView`
- `TranscriptGestureAccessibilityView`, `DemoRecoveryResize`
- `ConversationView`, `ConversationNoteSheet`, `ConversationColumnView`, `ConversationBackground`, `ConversationHeaderBackdrop`
- `WorkspaceNavigationHeader`, `WorkspaceVerticalConversationHeader`, `WorkspaceTextTrimLayout`, `WorkspaceUserBubbleLayout`, `workspaceTranscriptDesign`
