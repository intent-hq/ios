# ADR-0031: Meaning of transcript follow and slow-frame tuning constants

- Status: Accepted
- Recorded: 2026-11-20 (moved from code comments; the decisions are older)
- Applies to: `ConversationConstants.Transcript`, `Constants.Connection`
  (`Intent/Constants.swift`)

## Context

`Constants.swift` holds tuning values. Most names explain themselves. The
values below need a definition of what they measure.

## Decisions

### 1. Transcript follow tolerances and spacing

Applies to: `ConversationConstants.Transcript.followLandingTolerance`,
`streamingFollowMinimumInterval`, `streamingFollowDriftTolerance`

- `followLandingTolerance` (1 pt) is the maximum distance from the bottom for a
  completed forced follow.
- `streamingFollowMinimumInterval` (0.5 s) is the minimum spacing between
  follow-to-bottom scrolls while a response streams.
- `streamingFollowDriftTolerance` (1 pt) is the maximum drift of the pinned
  viewport before a streaming follow scrolls.

### 2. Slow inbound frames are logged above one 60 Hz frame

Applies to: `Constants.Connection.slowFrameLogThreshold`

An inbound frame whose off-main parse or MainActor dispatch takes longer than
this value (0.016 s, one 60 Hz frame) is logged as a slow frame.
