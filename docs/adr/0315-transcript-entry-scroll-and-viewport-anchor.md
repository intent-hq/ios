# ADR-0315: Transcript entry scroll and viewport anchor restoration

- Status: Accepted
- Recorded: 2026-11-20 (moved from code comments; the decisions are older)
- Applies to: `ConversationTranscriptViewportAnchor` (`Intent/Presentation/ConversationTranscriptViewportAnchor.swift`, `Intent/Presentation/ConversationTranscriptViewportAnchor+Application.swift`), `ConversationTranscriptScrollState` entry and restoration members (`Intent/Presentation/ConversationTranscriptScrollState.swift`)

## Context

The transcript scrolls once to its entry position when it opens. Entry
metadata (the new-messages divider) can arrive late, and the transcript view
can be covered and rehosted. The lazy stack realizes rows on demand, so rows
can change size after they were measured.

## Decisions

### 1. Entry scroll is a single state machine

Applies to: `ConversationTranscriptScrollState.EntryScroll`

The once-per-transcript entry scroll is one enum:

- `scheduled`: a loading trigger queued the entry timer.
- `awaitingScrollView`: the timer beat hosting; the scroll waits for the
  scroll-view finder to resolve.
- `settling`: the scroll was issued; it becomes `positioned` once the settle
  delay passes.
- `preserved`: rows were presented before the entry metadata, so the viewport
  was kept.

### 2. Visible content and gestures win over late entry metadata

Applies to: `ConversationTranscriptScrollState.preservePresentedViewport(distanceToBottom:)`, `initialScrollGeneration`

Visible content and user gestures take priority over late entry metadata.
`preservePresentedViewport` invalidates scheduled entry callbacks but keeps the
authoritative divider. `initialScrollGeneration` invalidates delayed
entry-scroll callbacks, including when an emptied transcript re-arms entry
scrolling for the next snapshot.

### 3. Restoration callbacks are retired by explicit follows and disappearance

Applies to: `retireViewportRestoration()`, `suspendEntryScroll()`, `resumeViewportTarget()`, `viewportOwnershipRevision`

An explicit follow or a disappearance retires even callbacks that were
captured but have not yet created a pending adjustment.
`suspendEntryScroll()` retires queued callbacks but keeps a completed entry for
the return. On resume, the rehosted view must measure afresh: a callback
captured while the view was covered cannot consume the new restoration, so
`resumeViewportTarget()` cancels restoration first. `viewportOwnershipRevision`
publishes ownership changes without observing every row measurement.

### 4. The anchor preserves a measured offset, once per divider revision

Applies to: `ConversationTranscriptViewportAnchor`

A late divider may resize an offscreen lazy row. The anchor preserves the
measured offset of the first fully visible row (or of an intersecting
oversized message), not just the identity of a visible target. Each divider
revision permits one correction; scrolling stays owned by the user.

### 5. A retained restoration runs in two steps: coarse scroll, then alignment

Applies to: `remove(id:generation:entryGeneration:ownershipRevision:)`, `retainedScrollIssued(target:generation:ownershipRevision:)`, `canConsumeRestoration(...)`, `hasReachedCoarseTarget(_:geometry:)`

- A retained target can leave the lazy stack while it is rehosted. The
  transcript owner cancels a deleted target or a restoration that a later
  gesture overrides.
- `retainedScrollIssued` bumps the ownership token. The published token
  rejects callbacks from before the command. The return of the command does
  not mean that the lazy stack has applied the requested alignment.
- Rehosting can report unavailable geometry before the row is realized, so
  non-finite or empty frames are ignored.
- A fresh callback can still describe the layout from before the scroll. The
  restoration settles only at the requested top alignment or at the actual
  content boundary. This also completes legitimate commands that were already
  aligned or did not move.

### 6. The restoration history keeps its first entries

Applies to: `recordRestorationEvent(_:)`, `maximumRestorationEvents`

The history is bounded (`maximumRestorationEvents` = 8). It keeps the saved
position and the application receipt even when later layout produces more
samples than the bound.

### 7. Retained alignment uses a tiny top marker and SwiftUI placement

Applies to: `ConversationTranscriptViewportAnchor.application(id:measurement:geometry:preserve:entryGeneration:)`, `restorationMarkerHeight`

The anchor point is computed against a tiny top marker
(`restorationMarkerHeight` = 1). It has no row-height singularity, even when
the retained message is as tall as the viewport or taller.

Both realization and final placement belong to SwiftUI. A native offset write
can succeed and then be replaced by the pending coarse `scrollTo`. Replacing
that target (`retainedAlignment`) avoids competing owners.
