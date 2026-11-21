# ADR-0048: Transcript follow, pin and takeover rules

- Status: Accepted
- Recorded: 2026-11-20 (moved from code comments; the decisions are older)
- Applies to: `ConversationTranscriptScrollPolicy` (`Intent/Presentation/ConversationTranscriptScrollPolicy.swift`)
- Related issues: #271, #272, #276, #280, #281, #338, #346, #350, #404, #426

## Context

`ConversationTranscriptScrollPolicy` holds the pure decisions for entry, follow
requests and user takeover. Geometry and re-pinning, landing, and
unrealized-end recovery live in extensions named after those
responsibilities (ADR-0049).

## Decisions

### 1. Message count changes

Applies to: `messageCountChangeDecision(from:to:hasInitiallyScrolled:isPrepend:)`, `isHistoryPrepend(from:to:)`

A wholesale transcript update needs different handling from an append. Empty
content clears the viewport state and re-arms entry scrolling; the next
non-empty snapshot runs that entry scroll. A shorter replacement can leave
UIKit's offset past its new end, so it enters the existing #350 resting
past-end recovery path.

Appends, including an append that arrives with history, still follow the live
tail. A pure prepend must never treat the existing last user row as a new send
or re-arm entry scrolling.

### 2. The entry scroll waits for the scroll view, with a bound

Applies to: `initialScrollStep(alreadyPerformed:scrollViewResolved:scrollViewWaitElapsed:entryMetadataReady:)`

A `scrollTo` issued before the transcript's `UIScrollView` is hosted is lost,
so the entry scroll waits for the finder to resolve. Once the bounded wait
elapses it runs anyway, so a finder that never resolves cannot leave the
transcript unscrolled. It runs at most once, whichever path gets there first.

### 3. Only a gesture unpins the transcript

Applies to: `scrolledAwayTransition(current:geometryAway:isInteracting:isEndRealized:)`

The scrolled-away flag drives Go to End and follow-to-bottom. Once pinned, the
transcript stays pinned until the user drags it up (#281). The only transition
to "scrolled away" is a gesture (the finger on the scroll view, or the
deceleration after it) that leaves the viewport past `atBottomThreshold`.
Content growth of any kind (a row re-measuring, a footer row, the keyboard,
streaming, an append) reads the same "away" geometry without a gesture and
keeps the current flag. #272, #280 and #281 each patched one such case.

Geometry within the threshold re-pins, gesture or not (the user dragged back,
or Go to End landed), provided that the end row is realized. A viewport
resting over an unrealized end row reads "at bottom" geometrically while it
shows nothing (#338). That edge keeps the current flag until the row realizes
and the ordinary rule applies.

### 4. Growth under a pinned viewport is followed

Applies to: `shouldRePinAfterContentGrowth(...)`, `shouldFollowToBottom(hasInitiallyScrolled:userIsScrolledAway:)`, `shouldFollowOnStreamingStateChange(...)`

A geometry edge that reads "away" without a gesture on a pinned, settled
transcript is content that grew under the viewport, and the pin follows it to
the new end. A follow that is already in flight lands there on its own. Under
the finger the edge is a gesture, not growth. Before the entry scroll has
decided, the viewport is not following yet.

Discrete, user-visible transitions (a message appended, Go to End, chrome
growing under the transcript) scroll whenever the transcript follows the
bottom. The thinking indicator is appended when streaming starts, so that edge
scrolls like any other append. Streaming ending only removes the indicator, and
the bottom-anchored viewport needs no scroll.

### 5. Clearing the scrolled-away flag follows only for Go to End

Applies to: `shouldFollowOnScrolledAwayCleared(goToEndRequested:)`

Clearing `userIsScrolledAway` is a follow only when Go to End cleared it. The
button sits outside the `ScrollViewReader`, so it records the request and
clears the flag for the `onChange` to scroll. A geometry edge that clears the
flag means the viewport already rests within `atBottomThreshold`, and nothing
needs to scroll. Such an edge can also be a transient mid-drag reading (a lazily
realized row re-measuring), and a forced scroll then fights the user's pan: the
interrupted animation left the geometry observer silent, so the next swipes
reached far up the transcript without Go to End (#280). The request is its own
flag, not the follow-in-flight state, so an edge that clears the flag while
another forced follow is in flight does not queue a second one.

### 6. Animation choices

Applies to: `shouldAnimateGoToEnd(geometry:)`, `GoToEndVisibilityTransition`, `goToEndVisibilityTransition(reduceMotion:)`, `animatesFollow(requested:reduceMotion:)`

Only the explicit Go to End request chooses animation by distance. Sweeping
through more than one visible screen realizes the lazy rows in between for no
reason (#404). Other follows keep their own animation choice.

Go to End slides in from the bottom by default, and fades only when Reduce
Motion is on (#426). Reduce Motion turns every transcript follow (Go to End,
auto-follow, landing corrections) into a jump; otherwise the caller's choice
stands.

### 7. Streaming deltas re-pin only a drifted viewport, rate-limited

Applies to: `shouldFollowStreamingDelta(...)`

Streaming deltas grow content that `.defaultScrollAnchor(.bottom)` already
keeps pinned, so a viewport at the bottom is never scrolled for them. A delta
re-pins only a viewport that drifted past `driftTolerance` while still inside
the at-bottom band (the user has not scrolled away), and at most once per
`minimumInterval`. `distanceToBottom` is nil until the scroll view has been
found; nothing scrolls then.

### 8. A debounced follow is re-validated when it runs

Applies to: `shouldExecuteFollow(...)`

Forced follows (Go to End, a new user message, the entry scroll, the thinking
indicator appearing) are all requested from a pinned viewport. At execution, a
raised `userIsScrolledAway` can only be a gesture that came after the request.
It wins whether it is still in progress (`isInteracting`) or already ended
away during the debounce. The forced follow yields without re-queuing itself,
and the gesture's geometry edges apply the scrolled-away rule from there.

An automatic follow is dropped when the user scrolled away during the
debounce (by the flag, or by the live distance leaving the at-bottom band), or
when the viewport is already pinned. An unknown distance (the scroll view is
not found yet) proves neither, so the follow still runs. The caller reconciles
a dropped automatic follow against the live geometry
(`shouldRePinAfterContentGrowth`): a distance past the band with no gesture is
content that grew during the debounce, not the user.

### 9. A gesture takes over a pending follow at once

Applies to: `gestureTakesOverPendingFollow(isInteracting:isFollowing:)`

A user gesture seen while a follow is pending (SwiftUI reporting a user-driven
scroll phase, or a geometry edge under UIKit tracking, dragging or
deceleration) takes the follow over immediately. The pending task (debounce or
landing loop) is cancelled when the gesture is seen, not re-checked when it
comes due. The gesture's final geometry edge can be dropped (#280) and its end
delivered before that check. The check would then read idle and pinned, and
scroll the user back from where the gesture left the viewport.

### 10. The takeover of a forced follow is latched

Applies to: `forcedFollowTakeoverLatch(current:geometryAway:isInteracting:)`, `shouldHonorForcedFollow(takenOverByGesture:)`

The takeover is latched for the rest of the gesture and for as long as the
gesture left the viewport away. A forced follow raised by content meanwhile
(the thinking indicator appearing) therefore does not revive the scroll that
the gesture cancelled. The latch releases once the viewport rests within
`atBottomThreshold` with no gesture in progress (the gesture ended pinned or
dragged back). An explicit request (Go to End, or the user's own message)
clears it outright, before asking. Only content-raised forced follows are
refused.

### 11. Follow terminals

Applies to: `FollowTerminal`

Every way a follow ends once requested. The recovery lifecycle consumes it
when a give-up was transferred to that follow (ADR-0047).

- `executed`: the follow scrolled. A forced follow carries its landing
  terminal; an automatic follow, which only waits out its animation, carries
  nil.
- `dropped`: an automatic follow whose re-validation at the due time failed
  (`shouldExecuteFollow`).
- `yielded`: a forced follow that came due under a gesture, or scrolled away.
- `cancelled`: a gesture took the pending follow over.
- `replaced`: a newer request superseded the follow before it came due.

The cases are in state-machine order, not alphabetical order.

## Consequences

- No code path except a gesture may set the scrolled-away flag. These rules
  replaced per-source patches (#271, #272, #276, #280, #281, #346, #404,
  #426), so a new source of content growth needs no new patch.
- A new follow source must go through `shouldExecuteFollow` and the takeover
  latch.
