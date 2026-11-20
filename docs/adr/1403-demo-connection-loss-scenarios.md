# ADR-1403: Connection-loss scenarios drive the real publisher from trigger files

- Status: Accepted
- Recorded: 2026-11-20 (moved from code comments; the decisions are older)
- Applies to: `DemoConnectionLoss` (`Intent/Demo/DemoConnectionLoss.swift`), `DemoNetworkPathMonitor` (`Intent/Demo/DemoNetworkPathMonitor.swift`)

## Context

UI regression tests need to drop and recover the connection, and change the
network path, at moments the test chooses. The scenarios are controlled by
files in `--demo-connection-loss-directory=`.

## Decisions

### 1. An opt-in seam that drives the real connection publisher

Applies to: `DemoConnectionLoss`

It is an opt-in UI regression seam, like the transcript fixture gates. Only
demo mode reads its trigger files. It drives the real connection publisher,
never the coordinator's overlay flag. A scenario runs once, even after Home or
reselection.

### 2. Evidence is written to files

Applies to: `DemoConnectionLoss.record(_:)`

Persistent evidence catches even one-frame presentations that XCUITest misses
while `activate()` waits for the application to settle.

### 3. A background drop keeps reconnecting

Applies to: `DemoConnectionLoss.sceneChanged(_:connection:)`

A real background drop keeps reconnecting. It never stops by itself, so the
scenario sets `.reconnecting(attempt: 1)` (except `activation-quick`, which
sets it on activation).

### 4. The network monitor is injected independently and shared by demo scenes

Applies to: `DemoConnectionLoss.networkAvailability`

It is an independent injected monitor, shared by the demo scenes just like the
live owner.

### 5. Initial data is held independently from the startup timeout trigger

Applies to: `DemoConnectionLoss.initialDataGate`, `DemoConnectionLoss.initialRoutingGate`

`--demo-connection-loss-pending-startup` holds fixture data on the
`initial-data` file, independently from the optional
`--demo-connection-loss-startup-timeout` trigger.

### 6. Content not viewed before the drop stays unloaded until the test says so

Applies to: `DemoConnectionLoss.conversationLoadGate(for:)`

With `--demo-connection-loss-hold-conversations`, conversation and note loads
that start after the drop wait for the `conversation-data` trigger.

### 7. Cancellation ends the scenario silently

Applies to: `DemoConnectionLoss.run(connection:coordinator:)`

Root teardown cancels the scenario. The catch block is empty because a
cancelled scenario must not revive Home.

### 8. Quick recovery uses a fixed short delay; tests sync on evidence

Applies to: `DemoConnectionLoss.runBackgroundScenario`, `quickRecoveryMilliseconds`

The non-sustained scenario deliberately spans rendering frames but recovers
within the production grace period. Tests synchronize on evidence files, never
on guessed sleeps.

### 9. The demo network monitor never touches real networking

Applies to: `DemoNetworkPathMonitor`

It is a file-gated UI fixture only. It never changes host or device networking
or a socket.

### 10. Cancellation retires the monitor silently

Applies to: `DemoNetworkPathMonitor.start(onUpdate:)`

Scene background or teardown retires the monitor and any pending report. The
catch block is empty for that reason.
