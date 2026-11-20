# ADR-0401: CoalescedRead runs one read at a time with at most one trailing pass

- Status: Accepted
- Recorded: 2026-11-20 (moved from code comments; the decisions are older)
- Applies to: `CoalescedRead` (`Intent/Services/CoalescedRead.swift`)

## Context

Stores reload data when an event marks their last result stale. Events can
arrive while a read is running, and a noisy feed can send them without pause.
`CoalescedRead` is the shared single-flight read for these stores.

## Decisions

### 1. An invalidation during a read earns at most one trailing pass per `run`

Applies to: `CoalescedRead.run(isCurrent:pass:)`

`run` joins the running read when there is one. Otherwise it runs `pass` once,
plus one trailing pass when an invalidation arrived mid-read. Later
invalidations leave the read dirty. They do not start more passes, so a noisy
feed cannot loop a caller. `isCurrent` is checked before every pass.

### 2. `run` returns true only to the owner, and only when the read ended dirty

Applies to: `CoalescedRead.run(isCurrent:pass:)`

`run` returns true only to the caller that started the read, and only when the
read is still current but was invalidated after its last pass started. A caller
that joined a running read always gets false.

1. A caller that ignores the result stays dirty and waits for the next explicit
   read, event, or reconnect.
2. A caller that runs again on true opts into "repeat until settled" and owns
   that loop. Use this only for adopters that must converge under a continuous
   feed. Only an invalidation during the last pass earns another run, and
   `cancel()` ends the loop.

### 3. A revision counter decides whether a pass is current

Applies to: `CoalescedRead.revision`, `CoalescedRead.Phase.running`

Every invalidation bumps `revision`, and so does `cancel()`. A pass is current
while `revision` is unchanged. The task in `Phase.running` yields the revision
that its last pass started at, which is how `run` detects a dirty end.

### 4. The caller schedules the read, and settles it when no pass runs

Applies to: `CoalescedRead.invalidate()`, `CoalescedRead.settleScheduled()`,
`CoalescedRead.Phase.scheduled`

`invalidate()` returns true when the caller must schedule a read, because none
is scheduled or running. The phase is then `scheduled`: an invalidation spawned
a read that has not started yet. When that scheduled read ends without running
its own pass, the caller must call `settleScheduled()`. Otherwise the phase
stays `scheduled` and later invalidations never schedule a read.

## Consequences

Stores must reuse `CoalescedRead` for single-flight reads. Do not hand-roll a
task plus pending and queued flags.
