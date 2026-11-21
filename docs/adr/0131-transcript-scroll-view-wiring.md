# ADR-0131: Transcript scroll view wiring

- Status: Accepted
- Recorded: 2026-11-20 (moved from code comments; the decisions are older)
- Applies to: `ConversationTranscriptView` (`Intent/Views/Conversation/Transcript/ConversationTranscriptView.swift`), `ConversationTranscriptView+History.swift` (`Intent/Views/Conversation/Transcript/ConversationTranscriptView+History.swift`), `ScrollViewMomentumProxy`, `ScrollViewFinder` (`Intent/Views/Conversation/Transcript/ConversationScrollViewSupport.swift`), `TranscriptGestureAccessibilityView` (`Intent/Views/Conversation/Transcript/ConversationTranscriptGestureProbe.swift`)
- Related issues: #271, #272, #280, #338, #346

## Context

The transcript is a SwiftUI `ScrollView` with a `LazyVStack` and a bottom
default anchor. Several SwiftUI scroll observations and a few direct reads of
the underlying `UIScrollView` drive one scroll-state machine.

## Decisions

### 1. One view owns the ordered observation wiring

Applies to: `ConversationTranscriptView`, `ConversationTranscriptView.transcriptScrollBase(proxy:dividerAnchorId:)`

`ConversationTranscriptView` keeps the ordered observation wiring.
Presentation, entry, follow, recovery, geometry re-pinning, and demo support
live in named extensions. None of them introduces a new view identity,
observation boundary, or state owner.

The modifier chain in `transcriptScrollBase` is one scroll-state machine.
Splitting it would hide the ordering between the gesture, geometry, and
past-end observations.

The read-only conveniences (`userIsScrolledAway`, `hasInitiallyScrolled`,
`isScrollingToBottom`) exist for the extensions. Mutations still target the
same parent-owned `scrollState`. No mutable forwarding API is exposed.

`followOwnsViewport` is true while a follow is pending: in its debounce, or
while it verifies its landing.

### 2. Follow handlers wait for the entry scroll

Applies to: `ConversationTranscriptView.transcriptScrollView(proxy:dividerAnchorId:)`

The follow handlers stay gated until the entry-scroll decision finishes, so
stream updates cannot pull the viewport away from the unread divider. Only
discrete transitions scroll. Streaming deltas ride the bottom anchor and at
most re-pin a drifted viewport (see `ConversationTranscriptScrollPolicy`).
Footer rows that resize the container are handled by the geometry observation
in `transcriptScrollBase`, not per source.

When streaming ends, the last delta and the thinking indicator leaving (or the
suggested prompts arriving) can leave a short transcript resting short of the
bottom (#346). So the bottom-band re-pin is scheduled.

### 3. Scrolled-away geometry is sampled as one value

Applies to: `ConversationTranscriptView.ScrolledAwayGeometry`

The scrolled-away edge is sampled together with the container height, so a
footer row that resizes the container and the edge that the resize causes
arrive in one action (#272). It is also sampled with the distance band, so an
edge that the observer drops is delivered again at the next band crossing
(#280, see `ConversationTranscriptScrollPolicy.distanceBand`).

### 4. Distance to bottom uses `visibleRect`

Applies to: `ConversationTranscriptView.transcriptScrollBase(proxy:dividerAnchorId:)`

`ScrollGeometry.containerSize` excludes the safe-area insets while
`contentOffset` includes them. Measuring with `containerSize` reads the top
inset (the navigation bar) at rest at the bottom. `visibleRect` spans the
full bounds, matching `UIScrollView`.

### 5. The scroll phase ending is an authoritative sample

Applies to: `ConversationTranscriptView.transcriptScrollBase(proxy:dividerAnchorId:)`,
`ScrollPhase.isUserDriven`

A user-driven phase beginning takes over any pending follow (see
`takeOverPendingFollowIfGesture`). A gesture's last geometry edge can arrive
after UIKit has cleared its deceleration flag, and the band observer drops a
flip that reverses within one layout pass (#280). So the phase ending is one
authoritative sample of where the gesture left the viewport. An explicit
follow that cut the gesture short (Go to End stopping a fling, or the tap that
sent a message) owns the flag instead.

User-driven phases are `.tracking`, `.interacting`, and `.decelerating`.
`.animating` is a programmatic scroll and `.idle` is at rest.

### 6. Past-end rest is watched separately and re-pinned (#271)

Applies to: `ConversationTranscriptView.transcriptScrollBase(proxy:dividerAnchorId:)`,
`ScrollViewMomentumProxy.rePinIfRestingPastEnd(confirming:isFollowing:)`,
`ScrollViewMomentumProxy.RePinOutcome`

A viewport that rests past the end of content taller than the container (a
blank band under the last message) reads "at bottom", so it is watched
separately and re-pinned.

`rePinIfRestingPastEnd` reads the live `UIScrollView`, not the geometry edge
that scheduled it. A bounce or a mid-animation frame also reads past the end
and must settle on its own (`.deferred`). The lazy stack re-lays out several
times per frame while the keyboard animates, reading past the end in some
passes and not others. So a re-pin is applied only after the same resting
geometry has been read twice: the caller passes the geometry from a
`.deferred` outcome back on the next check. A programmatic follow
(`isFollowing`) animates through the same geometry and is deferred like a
gesture, so the clamp cannot land mid-animation. `.unavailable` means the
scroll view has not been found, so the caller can fall back.

`.deferred(nil)` means past the end but still dragging, decelerating, or
following. `.deferred(geometry)` means read past the end for the first time.
Both mean: check again later.

### 7. Paging lays out the rows before a follow (#338)

Applies to: `ScrollViewMomentumProxy.pageTo(offsetY:)`

`pageTo` moves a resting viewport without animation, so the lazy stack lays
out the rows there before a follow back to the end.

### 8. Scroll view discovery

Applies to: `ScrollViewMomentumProxy.hasResolvedScrollView`, `ScrollViewFinder`,
`ScrollViewFinder.FinderView`, `ConversationTranscriptView.transcriptScrollBase(proxy:dividerAnchorId:)`

`hasResolvedScrollView` is the observable edge for "the transcript has been
hosted". It flips when the finder resolves, so the entry scroll can wait for it
instead of a fixed timer. It is sticky, not a liveness signal: weak zeroing
skips `didSet`, so it stays true after the scroll view deallocates while
`scrollView` and `distanceToBottom` are nil again.

`ScrollViewFinder` is a zero-size view that walks up to the enclosing
`UIScrollView`. The walk runs from `didMoveToWindow`, not from `makeUIView`.
When the representable is created its only ancestor is SwiftUI's platform-view
host and it has no window yet, so an eager walk stops one hop up and never
reaches the scroll view. Attaching to a window guarantees the full ancestor
chain. Re-attaching (for example after a hosting change) re-runs the walk
idempotently. A proxy swapped in while the view is already hosted is resolved
at once; otherwise resolution waits for the window attach.

The finder is hosted on the stack itself, not on a lazily realized row, so the
`UIScrollView` is found whichever rows exist.

### 9. Keyboard dismissal is a UIKit recognizer on the scroll view

Applies to: `ScrollViewFinder.KeyboardDismissTapGesture`

The keyboard-dismiss tap is installed directly on the transcript scroll view.
A SwiftUI tap gesture, or SwiftUI's hosting recognizer, would starve Textual's
UIKit link-tap recognizers in message content.

### 10. Older-history paging measures against settled frames

Applies to: `ConversationTranscriptView.preserveHistoryPosition()`

`preserveHistoryPosition` runs synchronously at page acceptance, before the
observable rows change. Request-time frames may be stale if the reader kept
scrolling. Post-await frames may already describe the newly inserted history.

After a prepend, the view waits for layout and retained-position restoration
before it measures the new top. A prepend can leave the reader in the prefetch
band without a new edge, and a fast reply could otherwise load pages against
old frames.

### 11. The gesture probe samples UIKit flags on demand

Applies to: `TranscriptGestureAccessibilityView`

The probe is demo-only accessibility diagnostics, sampled when XCTest queries
the value. UIKit interaction flags are not Observation dependencies. Caching
them in a SwiftUI body can leave an active report after deceleration has
ended.

### 12. Keyboard geometry logs read only geometry and timing

Applies to: `ConversationTranscriptView.logKeyboardGeometry(_:notification:)`

The log reads only the keyboard frame and animation timing keys, never the
whole notification payload.
