# 0060. Transcript pin, follow and user takeover

**Status:** Accepted (recorded 2026-11-20 from code comments)

## Context

The conversation transcript is a lazy stack with `.defaultScrollAnchor(.bottom)`. Rows re-measure after they realize, footer rows and the keyboard resize the container, and streaming grows the content many times a second. Each of these reads as "away from the bottom" without a user gesture. Earlier fixes patched one source at a time (#271, #272, #276, #280, #281, #346, #404, #426). This record states the rules that replaced the patches.

## Decision

1. **Only a gesture unpins.**
   1. The scrolled-away flag (`userIsScrolledAway`) drives Go to End and follow-to-bottom. Once pinned, the transcript stays pinned until the user drags it up (#281).
   2. The only transition to "scrolled away" is a gesture (the finger or its deceleration) that leaves the viewport more than `atBottomThreshold` from the bottom. Content growth of any kind keeps the current flag.
   3. A geometry edge within the threshold re-pins, gesture or not. Exception: over an unrealized end row the geometry reads "at bottom" while nothing shows (#338), so that edge keeps the current flag until the row realizes.
   4. An "away" edge without a gesture on a pinned, settled transcript is content growth. The pin follows to the new end. A follow in flight lands on its own. Before the entry scroll, nothing is following yet.
2. **Distance bands.** `onScrollGeometryChange` can drop the second of two flips inside one layout pass, which froze the flag for a whole scroll (#280). The view also observes the distance in bands of `atBottomThreshold`, so the next band crossing delivers the current flag again.
3. **Which changes follow.**
   1. Discrete, visible transitions (an append, Go to End, chrome growing under the transcript) follow when the transcript is pinned.
   2. Streaming start appends the thinking indicator and follows like an append. Streaming end only removes it and issues no scroll.
   3. A streaming delta does not scroll a viewport at the bottom; the bottom anchor keeps it pinned. A delta re-pins only a viewport that drifted past `driftTolerance` but stays inside the at-bottom band, at most once per `minimumInterval`. With no scroll view yet, nothing scrolls.
   4. A pure history prepend never counts the existing last user row as a new send and never re-arms entry scrolling. An append that arrives with history still follows the tail.
   5. Empty content clears viewport state and re-arms the entry scroll for the next non-empty snapshot. A shorter replacement can leave the offset past the new end, so it uses the past-end re-pin.
4. **Entry scroll.** A `scrollTo` issued before the UIScrollView is hosted is lost. The entry scroll waits for the finder, but runs after a bounded wait even if the finder never resolves. It runs at most once.
5. **Go to End.**
   1. Go to End sits outside the `ScrollViewReader`. It records `goToEndRequested` and clears the flag; only that request turns "flag cleared" into a follow. A geometry edge that clears the flag scrolls nothing, because a forced scroll during a pan fights the user (#280). The request is its own flag, so an edge during a forced follow does not queue a second one.
   2. Only Go to End chooses animation by distance. A sweep over more than one screen realizes rows for nothing (#404), so it jumps.
   3. Go to End slides in from the bottom. With Reduce Motion it fades (#426).
   4. Reduce Motion turns every follow (Go to End, auto-follow, landing corrections) into a jump.
6. **Debounced follows re-validate when they run.**
   1. Forced follows (Go to End, a new user message, the entry scroll, the thinking indicator) start from a pinned viewport. A raised flag at execution is a later gesture. It wins, and the forced follow yields without re-queuing.
   2. An automatic follow is dropped when the user scrolled away during the debounce (by flag or live distance) or when the viewport is already pinned. An unknown distance proves neither, so the follow runs. The caller reconciles a dropped follow against live geometry as content growth.
7. **Gesture takeover.**
   1. A gesture seen while a follow is pending cancels the pending task at once. It is not re-checked at the due time, because the gesture's last edge can be dropped (#280) and the follow would scroll the user back.
   2. The takeover of a forced follow latches (`forcedFollowTakenOverByGesture`) for the rest of the gesture and while the viewport stays away. Content-raised forced follows are refused while it is set. It releases when the viewport rests within `atBottomThreshold` with no gesture. Go to End and the user's own message clear it before they ask.
   3. An explicit request (Go to End, the user's message) clears `isUserScrollPhase`, so the phase end that follows belongs to the request, not the gesture.
8. **Geometry re-pins.**
   1. `ViewportGeometry` includes the adjusted insets, because the keyboard or safe area can change them while offset, content size and bounds stay the same. `distanceToBottom` is 0 at rest at the bottom and negative while bouncing or when content is shorter than the container.
   2. **Past end (#271).** A viewport past the end of content taller than its container hides the last rows over a blank band. A resting viewport is re-pinned by exactly the distance. A viewport still dragging or decelerating (the bounce back included) is deferred. Content shorter than the container is never past the end.
   3. **Container resize (#272, #276).** A footer row resizing the container while pinned re-pins. Scrolled away, nothing moves. Under the finger, decelerating, or during recovery the re-pin is deferred to the settle re-check; the edge the resize carries applies meanwhile. On settle: within the band, follow; past the band while still following, pin straight back, because only a gesture may set the flag. A re-check defers again while a follow that another settle source issued is in flight.
   4. **Bottom band (#346).** A short transcript that grows past one page can rest a line short of the end, under the threshold and with no gesture, so nothing closes the gap. A pinned, settled edge into band 0 schedules a settle re-check. A follow in flight does not cancel the request; the re-check defers until it lands. On settle, a viewport more than `driftTolerance` short of the bottom gets the ordinary automatic follow. Negative distance belongs to the past-end clamp; unknown distance proves nothing.
9. **Case order.** The cases of `FollowTerminal`, `FollowLandingContinuation` and `UnrealizedEndRecoveryContinuation` follow their state machines, not the alphabet.

## Consequences

- No code path except a gesture may set the scrolled-away flag. A new source of content growth needs no new patch.
- New follow sources must go through `shouldExecuteFollow` and the takeover latch.

## Code

- `ConversationTranscriptScrollPolicy`: `scrolledAwayTransition`, `shouldRePinAfterContentGrowth`, `shouldFollowToBottom`, `shouldFollowOnStreamingStateChange`, `shouldFollowStreamingDelta`, `isHistoryPrepend`, `messageCountChangeDecision`, `initialScrollStep`, `shouldFollowOnScrolledAwayCleared`, `shouldAnimateGoToEnd`, `GoToEndVisibilityTransition`, `animatesFollow`, `shouldExecuteFollow`, `gestureTakesOverPendingFollow`, `forcedFollowTakeoverLatch`, `shouldHonorForcedFollow`, `FollowTerminal`
- `ConversationTranscriptScrollPolicy` (geometry): `ViewportGeometry`, `distanceToBottom`, `distanceBand`, `isPastEnd`, `isDriftedWithinBottomBand`, `rePinDecision`, `containerHeightChangeDecision`, `deferredContainerRePinDecision`, `shouldRecheckBottomBandAfterEdge`, `bottomBandRePinDecision`
- `ConversationTranscriptScrollState`: `isUserScrollPhase`, `forcedFollowTakenOverByGesture`, `goToEndRequested`, `isScrollingToBottom`, `lastFollowToBottomAt`
- `Constants`: `atBottomThreshold`
