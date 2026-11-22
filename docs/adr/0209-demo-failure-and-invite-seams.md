# ADR-0209: Failure and invite seams reach error and sheet states without a host

- Status: Accepted
- Recorded: 2026-11-20 (moved from code comments; the decisions are older)
- Applies to: `DemoFailureFixtures` (`Intent/Demo/DemoFailureFixtures.swift`), `DemoInviteJoin` (`Intent/Demo/DemoInviteJoin.swift`)
- Related issues: ios#462

## Context

Error states and the invite join sheet are hard to reach with a live host.
These Debug-only seams make them reachable with `--demo-data`.

## Decisions

### 1. Failures are opt-in by name and fire a fixed number of times

Applies to: `DemoFailureFixtures`

They are Debug-only failure seams for the hands-on check of error states:
`--demo-failures=pr-search,pr-load-more,pr-detail,file-preview`, plus the
first-read lists `workspace-list,agent-list,note-list` (ios#462), with
`--demo-data`. Each failure fires a fixed number of times per launch, so Retry
recovers. For the first-read lists the count is per workspace, so a workspace
the iPad opens at launch does not use up another workspace's failures.
`failedReads` counts the reads failed so far per first-read fixture and
workspace.

### 2. First-read lists fail every automatic read so only Retry recovers

Applies to: `DemoFailureFixtures.firstReadFailure(for:params:)`

The value is a list fixture and how many reads it fails. The workspace stores
read once on open and again on seeing the live connection, so both reads fail
and only Retry recovers. Agent group and Assistant reads are left alone.

### 3. The injected timeout matches the live wording

Applies to: `DemoFailureFixtures.requestTimedOut`

It matches the wording of the live connection's request timeout.

### 4. The invite seam answers host and own-Mac calls locally

Applies to: `DemoInviteJoin`

It is the demo seam for the `intent://invite` join sheet
(`--demo-invite=<scenario>` with `--demo-data`). It presents a fixture invite
and answers the host and own-Mac calls locally, so UI tests and screenshots
reach every sheet state without a shared host. Scenarios: `first-join`
(confirm, prove through the Mac), `existing-access` (confirm with a login this
device has), `no-mac`, `expired`.

### 5. Fixture fingerprints are 32 bytes; the host delay shows progress

Applies to: `DemoInviteJoin.fingerprintBytes`, `DemoInviteJoin.hostDelay`

SHA-256 fingerprints are 32 bytes. The host delay is long enough for the
progress state to render in screenshots.

### 6. The fixture invite opens after the first screen is routed

Applies to: `DemoInviteJoin.present(_:)`

It opens the fixture invite once the first screen is routed.
