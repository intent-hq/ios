# ADR-0318: Transcript geometry, re-pins, follow landing and end recovery

- Status: Accepted
- Recorded: 2026-11-20 (moved from code comments; the decisions are older)
- Applies to: `ConversationTranscriptScrollPolicy` extensions (`Intent/Presentation/ConversationTranscriptScrollPolicy+Geometry.swift`, `Intent/Presentation/ConversationTranscriptScrollPolicy+Landing.swift`, `Intent/Presentation/ConversationTranscriptScrollPolicy+Recovery.swift`)
- Related issues: #271, #272, #276, #338, #346

## Context

These extensions read the live geometry of the transcript's scroll view and
decide re-pins after content or container changes, how a forced follow lands,
and how the transcript recovers from a viewport that rests on unrealized rows.
The pin rules they rely on are in ADR-0317.

## Decisions: geometry

### 1. Geometry includes the adjusted insets

Applies to: `ViewportGeometry`

`ViewportGeometry` is everything that a landing or re-pin decision reads from
the live scroll view. `containerHeight` is the full bounds. The adjusted insets
are part of it, because the keyboard or the safe area can change them between
two reads while offset, content size and bounds stay the same.

### 2. Distance to bottom

Applies to: `distanceToBottom(contentHeight:contentOffsetY:containerHeight:bottomInset:)`

The distance is the points between the viewport's bottom edge and the end of
the content: 0 at rest at the bottom, negative while bouncing past it or when
the content is shorter than the container.

### 3. Past the end

Applies to: `isPastEnd(distanceToBottom:contentHeight:containerHeight:verticalInsets:atBottomThreshold:)`

The viewport is past the end when it sits beyond the end of content that is
taller than its container. The last rows are hidden above a blank band, yet
`isScrolledAway` reads "at bottom". Content shorter than the container rests at
a negative distance by construction and is never past the end.
`verticalInsets` is the container's top plus bottom content inset, which
`containerHeight` (the full bounds) includes but the content does not.

### 4. The drift band is checked on the live distance

Applies to: `isDriftedWithinBottomBand(distanceToBottom:driftTolerance:atBottomThreshold:)`

An automatic follow may re-pin from the band between `driftTolerance` and
`atBottomThreshold`. `userIsScrolledAway` lags the geometry (and is frozen
during a programmatic scroll), so the live distance is checked against the same
threshold instead of trusting the flag alone.

## Decisions: re-pins

### 5. A resting viewport past the end is re-pinned (#271)

Applies to: `rePinDecision(...)`, `RePinDecision`

Past the end, the offset is stale for content that shrank, and the distance is
exactly the correction. A bounce past the bottom reads the same geometry, so a
viewport that the user is still dragging, or that is decelerating (including
the bounce back), is left to settle (`deferred`: check again later). `none`
means the viewport rests within the content.

### 6. A container resize re-pins a following viewport (#272)

Applies to: `containerHeightChangeDecision(...)`, `ContainerRePinDecision`

A footer row that appears or disappears under the transcript resizes its
container while `contentOffset` stays where it was (#272). At rest at the
bottom, that slides the last rows under the new row and the geometry reads
scrolled away, so a following viewport is re-pinned to the bottom. When
scrolled away, the container resizes at its bottom edge and the content under
the reader does not move, so nothing is adjusted. Before the entry scroll the
viewport is not following yet.

A viewport under the user's finger, or still decelerating from a fling
released just before the row lands (including the bounce back at the bottom),
is not pinned right away: the re-pin would fight the pan or snap the fling
back. It is deferred to `deferredContainerRePinDecision` once the gesture has
settled, as the #271 past-end clamp does. The edge that the resize carries is
applied meanwhile, so a row taller than the threshold shows Go to End as usual.
Recovery also defers the pin: its temporary page-up must survive until
recovery follows back. Ordinary follows still pin immediately.

The cases: `deferred` (a gesture or recovery owns the viewport; re-check after
it settles), `follow` (settled short of the bottom inside the at-bottom band
while following; the ordinary automatic follow closes the gap), `none` (the
container is unchanged, or the viewport is not following), `rePin` (pin
straight back to the bottom).

### 7. The settle re-check after a container resize

Applies to: `deferredContainerRePinDecision(...)`

The re-check covers a re-pin deferred while interacting, and the per-frame
re-pins that a resize animation (the keyboard) issued.

- Still interacting, or with a follow in flight that another settle source
  (`bottomBandRePinDecision`, the past-end clamp) already issued: the re-pin
  would cancel that follow mid-animation and re-issue the same scroll, so it is
  deferred again and reads the landed distance instead.
- Settled short of the bottom within the at-bottom band while still
  following: the viewport is followed to the bottom. A row shorter than the
  threshold leaves exactly that gap under the last message, with no Go to End
  and no further geometry edge to close it.
- Settled past the threshold while still following: it is pinned straight
  back. Only a gesture may set `userIsScrolledAway`, so a following viewport
  that rests away with no gesture is one that the resize displaced. The
  keyboard shrinking the transcript while the lazy stack re-estimated its rows
  walked the offset to the very top (#276), and the per-frame re-pins had
  consumed the away edge that the growth re-pin would otherwise act on.
- A fling that carried the user past the threshold set the flag as its phase
  ended, and is left where it stopped. A rest past the end belongs to the #271
  clamp. An unknown distance (no scroll view) proves nothing.

### 8. A transcript resting just short of the end is re-checked (#346)

Applies to: `shouldRecheckBottomBandAfterEdge(...)`, `bottomBandRePinDecision(...)`, `BottomBandRePinDecision`

A new conversation's transcript starts shorter than its container, at a
negative distance, and its first reply grows it past one page. The bottom
anchor takes the pin over mid-growth, and the viewport comes to rest a line or
two short of the end (#346): under `atBottomThreshold`, so Go to End stays
hidden, and with no gesture, so the away edge never fires. Streaming deltas
read the distance before their content is laid out and are rate-limited, and
streaming ending issues no scroll, so nothing closes the gap.

The growth does cross from a negative band into band 0. That edge, read on a
pinned, settled transcript, schedules a settle re-check. A follow in flight
does not suppress it: the last rows may lay out during that follow's
completion window, and its drain re-pins only on an away edge, so the request
is kept and the re-check defers until the follow lands. An away edge without a
gesture is content growth past the band: `shouldRePinAfterContentGrowth`
re-pins it at once, and the re-check validates that single scroll once the
growth has settled (a reply that ends with several suggested prompts swaps in
more than `atBottomThreshold` at stream end). Under the finger the edge is a
gesture, not growth. Before the entry scroll the viewport is not following yet.

The re-check also runs when streaming ends. Interacting, or with a follow in
flight that a re-pin would land under, it is deferred again. Once settled, a
viewport that is still following and rests short of the bottom (past
`driftTolerance`, so layout rounding is left alone) is followed there through
the ordinary automatic follow. That follow re-validates the geometry when it
runs: within the at-bottom band it scrolls, and past `atBottomThreshold` its
drain re-pins the distance as content growth (`shouldRePinAfterContentGrowth`).
With no gesture, the flag cannot have been raised. Content still shorter than
the container rests at a negative distance that the past-end clamp owns
(#271). An unknown distance (no scroll view) proves nothing. When scrolled away
or before the entry scroll, nothing is following.

The cases: `deferred` (following, but under the finger, decelerating, or with
a follow in flight; re-check on settle), `none` (not following, or resting
within `driftTolerance`, at a negative distance owned by the clamp, or at an
unknown distance), `rePin` (following and settled, with no gesture, at rest
more than `driftTolerance` short of the bottom, including past
`atBottomThreshold`).

## Decisions: forced-follow landing

### 9. Landing and recovery are separate bounded state machines (#350)

Applies to: `ConversationTranscriptScrollPolicy+Landing.swift`, `ConversationTranscriptScrollPolicy+Recovery.swift`

The bounded forced-follow landing and its demo report are in the Landing
extension. The complementary blank-end recovery state machine and its demo
report are in the Recovery extension (#350). The cases of their enums are in
state-machine order, not alphabetical order. The pinned SwiftLint 0.65.1
`sorted_enum_cases` rule does not traverse extensions, and restoring its
directives fails strict lint with `superfluous_disable_command`, so the files
have no directives for it.

### 10. A forced follow ends only when the geometry confirms it (#281)

Applies to: `followLandingStep(...)`, `FollowLandingContinuation`, `FollowLandingTerminal`, `FollowLandingStep`

A forced follow (entry, a new user message, the thinking indicator, Go to End)
is complete only when the live geometry confirms it (#281). `scrollTo` targets
the bottom as laid out when it is issued, and rows that the lazy stack realizes
afterwards re-measure. When they are taller, the viewport rests short of the
bottom (Go to End on the demo transcript landed 379 points short). When they
are shorter, it rests past the end over a blank band (#271). Ending the follow
on a timer then copied that geometry into the flag, Go to End showed, and every
later append was skipped as "user scrolled away".

The landing is polled instead:

1. Two identical reads mean the geometry is at rest.
2. A rest short of the bottom is scrolled again (`scrollAgain`), and a rest
   past the end is clamped (`clampPastEnd`), each a bounded number of times.
3. A bound that runs out leaves the pin as it is (`giveUp`), so no follow ever
   shows Go to End without a gesture.
4. Content shorter than the container rests at a negative distance and is
   landed.
5. The user takes over (`yieldToUser`) by a gesture in progress, or by one
   that already set `userIsScrolledAway` between two polls. A forced follow
   starts pinned, so the flag being raised while it lands is the user's later
   intent; the gesture rule then owns the flag.

`settling` means there is no scroll view yet, or the geometry moved since the
last poll. `landed` means at rest within `landingTolerance` of the bottom.
`giveUp` means a timeout, or the bounded corrections are spent.

Short of the bottom is judged against `landingTolerance`, not the at-bottom
band. The last rows that the lazy stack realized grew the content by less than
`atBottomThreshold`, so the viewport rested a few dozen points short while
reading "at bottom" (Go to End hidden), with the rows under the last message
(suggested prompts on entry, the thinking indicator after a send) still below
the viewport (#304, #305). Past the end keeps the band: a rest that far past
the end is a blank band, and the bounce back reads the same geometry.

### 11. The demo landing report

Applies to: `forcedFollowLandingSummary(outcome:corrections:endRecovery:)`

Under `--demo-data`, the transcript's accessibility value holds the last forced
follow's outcome and the corrections it spent, for example
`lastForcedFollow=landed corrections=1`, or `lastForcedFollow=pending` while
one is in flight (or before the first). The XCUITests use it to assert that
the follow landed rather than gave up with the pin kept, which the visible
geometry alone cannot tell apart within the at-bottom band (#304, #305).
`endRecovery` (`UnrealizedEndRecoveryReport.summary`) is appended once the
follow has reported, never to the pending report that the tests compare whole.

## Decisions: unrealized-end recovery

### 12. Recovery searches upward for realized rows (#338)

Applies to: `unrealizedEndRecoveryStep(...)`, `UnrealizedEndRecoveryContinuation`

A lazy stack can report the estimated bottom without realizing its end row
(#338). The recovery tries the end target once (`followToEnd`) when the
viewport rests short of the bottom. After each unsuccessful end jump it
searches farther upward (`recover(pageOffsetY:)`: page the offset up so the
lazy stack realizes rows again, then follow back to the end). The final
bounded attempt realizes the top before following back.

A failed jump, or a missing end target, can leave the viewport short of the
end at the paged-up offset. The recovery continues searching there, because it
owns the viewport and suppresses other re-pins. User gestures, an explicit
reading position and past-end clamping still win.

`settling` covers: no scroll view yet, a follow or gesture in flight, geometry
that moved since the last poll, or a geometry that another path corrects.
`recover` also applies at rest at the bottom by geometry with no end row
realized, or after a follow that changed nothing.

### 13. Recovery terminals

Applies to: `UnrealizedEndRecoveryTerminal`

The lifecycle and the report consume the terminal (ADR-0316,
`unrealizedEndRecoveryReport`).

- `notNeeded`: the end row is realized, the viewport is not following, or the
  content is shorter than the container.
- `giveUp`: a timeout, or the bounded corrections are spent, with the end row
  still unrealized. The lifecycle shows Go to End, or transfers the give-up to
  a follow that owns the viewport.
- `yieldToUser`: a gesture, a rest away, or a follow requested meanwhile
  claimed the viewport while a correction had it paged up. The viewport is
  theirs.

### 14. Follow back only when nothing claimed the viewport

Applies to: `unrealizedEndRecoveryMayFollowBack(isInteracting:userIsScrolledAway:isFollowing:)`

A correction that paged the viewport up follows back to the end only when
nothing claimed the viewport while the rows realized. A gesture (the finger, or
the deceleration after it), a rest that the gesture left away, or a follow
requested meanwhile (the user's message, Go to End, content) each own the
viewport from there and would be scrolled over by the follow back. The
correction yields instead.

### 15. The demo recovery report

Applies to: `UnrealizedEndRecoveryReason`, `UnrealizedEndRecoveryReport`, `unrealizedEndRecoveryReport(outcome:corrections:episodes:endRealized:cancelled:)`

The report is demo-only. It says how the last episode resolved, with the
evidence that the label rests on. Only `unrealizedEndRecoveryReport` decides
the reason, so a reader cannot be told `recovered` by a resolution that never
realized the end row.

- `cancelled`: the episode's task was cancelled (a takeover, or the view
  disappearing) before it resolved. This overrides whatever terminal it
  reached.
- `gaveUp`: the budget was spent or the timeout hit over an unrealized end
  row; Go to End is shown.
- `noCorrectionNeeded`: the last episode resolved without spending a
  correction.
- `notAttempted`: no episode was ever armed on this transcript.
- `recovered`: the last episode corrected the viewport at least once, and the
  end row was realized when it resolved. Both are required.
- `recovering`: an episode is armed and has no terminal yet (`outcome` is nil).
- `unverified`: the last episode corrected the viewport and resolved as
  nothing left to do (not following, content short of the container) with the
  end row still unrealized. It is not recovered, and not a give-up either: the
  budget was not spent and Go to End is not shown.
- `yieldedToUser`: a gesture, a rest away or a follow claimed the viewport.
