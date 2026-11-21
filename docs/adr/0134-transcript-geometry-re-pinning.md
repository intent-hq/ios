# ADR-0134: Transcript geometry edges and re-pinning

- Status: Accepted
- Recorded: 2026-11-20 (moved from code comments; the decisions are older)
- Applies to: `ConversationTranscriptView+Geometry.swift` (`Intent/Views/Conversation/Transcript/ConversationTranscriptView+Geometry.swift`): `logKeyboardGeometry(_:notification:)`, `logScrollGeometry(_:)`, `scheduleRePinIfRestingPastEnd(proxy:confirming:)`, `isFollowing`, `rePinAfterContainerHeightChange(from:to:proxy:)`, `scheduleDeferredContainerRePin(proxy:)`, `scheduleBottomBandRePinIfNeeded(proxy:)`, `scheduleBottomBandRePin(proxy:)`, `applyScrolledAwayEdge(geometryAway:isInteracting:proxy:)`, `isUserInteracting`, `applyLiveScrolledAwayEdge(isInteracting:proxy:)`
- Related issues: #271, #272, #276, #338, #346, #711

## Context

Geometry edges from the scroll observations decide whether the reader is
pinned to the bottom or scrolled away. Layout changes (footer rows, the
keyboard, lazy rows re-estimating, history prepends) move the geometry without
a user gesture. The rule is: only a gesture may break the pin.

## Decisions

### 1. Debug geometry logging is privacy-safe

Applies to: `logKeyboardGeometry(_:notification:)`, `logScrollGeometry(_:)`

Keyboard frames are screen coordinates, not the transcript's occluded height.
The keyboard log reads only the geometry and timing keys and never logs the
notification's whole payload. The scroll trace is debug device tracing for
question and keyboard teardown. It never includes conversation content or
backend identifiers, and does no work in Release.

### 2. Past-end re-pin waits for two agreeing checks

Applies to: `scheduleRePinIfRestingPastEnd(proxy:confirming:)`

The live scroll view is checked again after the geometry has had time to
settle (`pastEndSettleMilliseconds`), because a bounce or a mid-animation frame
also reads past the end. The offset is clamped back to the bottom once two
checks agree. A viewport still bouncing or re-laying out is checked again
after it settles, because the past-end edge has already fired and will not
fire twice. A programmatic follow in flight is deferred the same way, so the
clamp cannot land mid-animation. Without a scroll view to clamp, a following
viewport is pinned back through SwiftUI's own layout. The pin is never broken
for a blank band that the user did not scroll to.

### 3. What counts as following

Applies to: `isFollowing`

A follow is in flight from its request until its landing is verified. An
unrealized-end correction on its way back to the end counts too (it is the
lifecycle's viewport owner), and so does a Go to End tap until its request is
made.

### 4. Footer rows resizing the container (#272, #276)

Applies to: `rePinAfterContainerHeightChange(from:to:proxy:)`

A footer row that appears or disappears under the transcript resizes its
container while UIKit keeps `contentOffset`. At rest at the bottom, the last
rows slide under the new row and the geometry reads scrolled away (#272).

1. While following, the viewport is pinned straight back to the bottom, and a
   follow in flight is restarted so it targets the new bottom. The edge this
   geometry carries is recorded but not applied; the pinned geometry that
   follows carries the real one.
2. The pin goes through SwiftUI's own layout (`scrollTo("scroll-bottom")`).
   When this action runs, the `UIScrollView` bounds still read the old height,
   so an offset computed from them lands at the old bottom.
3. Under the finger or while decelerating, the pin is deferred to a settle
   re-check and the edge is applied as usual (see
   `ConversationTranscriptScrollPolicy.containerHeightChangeDecision`).
4. Recovery owns its page-up until it follows back, so container pins wait for
   that ownership to end instead of undoing the correction.
5. An issued pin is re-checked on settle too. A resize animated over several
   frames (the keyboard) pins on each frame against a lazy stack that is still
   re-estimating its rows. It could leave the viewport far from the bottom with
   the away edge consumed here (#276).
6. Scrolled away, the content under the reader already stays put, because the
   container resizes at its bottom edge.
7. The function returns false when the edge is to be applied as usual.

### 5. The deferred container check

Applies to: `scheduleDeferredContainerRePin(proxy:)`

The viewport is checked again once the container resize has had time to
settle: a re-pin deferred while interacting, or the last of the per-frame pins
of an animated resize. It checks again while the gesture has not settled.

1. Short of the bottom inside the band while still following, the viewport is
   followed there through the ordinary automatic follow, which validates the
   geometry again when it runs.
2. Past the threshold with no gesture, the resize displaced the viewport. It
   is pinned straight back through a forced follow, whose landing is verified
   against the live scroll view (#276).
3. The gesture predicate includes the SwiftUI phase. UIKit clears its
   deceleration flag a moment before the phase ending records where the fling
   left the viewport, and a fling past the threshold must not be snapped back.

### 6. The bottom-band re-check (#346)

Applies to: `scheduleBottomBandRePinIfNeeded(proxy:)`, `scheduleBottomBandRePin(proxy:)`

A band-observer edge (or streaming ending) on a pinned, settled transcript can
be a short transcript that grew past one page and came to rest a line or two
short of the end (#346). It can also be growth past the band whose immediate
re-pin is not yet validated (see
`ConversationTranscriptScrollPolicy.shouldRecheckBottomBandAfterEdge`).

1. A follow in flight defers the re-check rather than dropping it.
2. The re-check is scheduled only from those two sources, never from a follow
   draining. A follow that lands a rounding error short would otherwise check
   and scroll itself again without bound.
3. The live distance is checked after the geometry has had time to settle,
   because the rows that the growth realized may still be laying out. It
   checks again while a gesture or a follow is in progress.
4. A following viewport that rests short of the bottom is followed there
   through the ordinary automatic follow. That follow validates the geometry
   again when it runs, and past the band it re-pins the growth when it drains.

### 7. Applying a scrolled-away edge

Applies to: `applyScrolledAwayEdge(geometryAway:isInteracting:proxy:)`,
`ConversationTranscriptScrollPolicy.scrolledAwayTransition`

A geometry edge updates `userIsScrolledAway` under the rule that only a
gesture may break the pin. A pinned viewport that content grew under is
followed straight back to the bottom.

1. The owned follow defers scrolling until layout settles and bounds its
   corrections. Scrolling synchronously here can loop while expanded lazy rows
   change size.
2. `isInteracting` defaults to the live gesture state. A phase ending passes
   true for its final sample.
3. The takeover latch is released against the live state, so a phase ending
   while pinned releases it at once.
4. An at-bottom edge over an unrealized end row clears nothing (#338). The row
   realizing replays the live edge (see the end marker's `onAppear`).
5. A history prepend's coarse restoration can briefly cross the bottom band.
   That layout is not a user returning to the tail (#711). While an older-page
   task runs, the reading position is kept until the page settles. Gestures
   and explicit follows still take ownership at once.

### 8. One gesture predicate

Applies to: `isUserInteracting`

Every scrolled-away and forced-follow decision reads one gesture predicate:
the `UIScrollView` flags once the finder has resolved, or the SwiftUI scroll
phase. The phase also covers a gesture on a transcript whose scroll view the
finder has not resolved yet.

### 9. Replaying the live distance

Applies to: `applyLiveScrolledAwayEdge(isInteracting:proxy:)`

The live distance is applied as a geometry edge at the moments when the
observer's edges were suppressed or may have been dropped: a follow draining,
or the user taking over from a forced follow.
