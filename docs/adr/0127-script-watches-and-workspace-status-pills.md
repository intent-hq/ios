# ADR-0127: Script watches and workspace status pills

- Status: Accepted
- Recorded: 2026-11-20 (moved from code comments; the decisions are older)
- Applies to: `WorkspaceStatusPillsRow`, `MonitoredScriptsRow` (`Intent/Views/Conversation/StatusStrip/MonitoredScriptsRow.swift`), `ScriptWatchPills` (`Intent/Views/Conversation/StatusStrip/ScriptWatchPills.swift`), `ScriptMonitorClock`, `EnvironmentValues.scriptMonitorPresentationDate` (`Intent/Views/Conversation/StatusStrip/ScriptMonitorClock.swift`), `ScriptMonitorPresentation` (`Intent/Views/Conversation/StatusStrip/ScriptMonitorPresentation.swift`), `ScriptMonitorDetailView` (`Intent/Views/Conversation/StatusStrip/ScriptMonitorDetailView.swift`), `WorkspaceStatusPill`, `MarqueeText`, `MarqueeMotion`, `WorkspaceStatusPillsLayout` (`Intent/Views/Conversation/StatusStrip/WorkspaceStatusPill.swift`)

## Context

Script watches notify an agent about a script run. The status area above the
composer lists them, and a sheet shows the details of one watch. The workspace
design shows watches and PR monitors as pills in one row.

## Decisions

### 1. Watch metadata describes triggers, not the script's state

Applies to: `ScriptMonitorPresentation`, `ScriptMonitorDetailView`

Watch metadata describes notification triggers. It never describes the runtime
state of a script. The detail sheet is read-only and uses the app's shared
sheet chrome.

### 2. The sheet host outlives an empty status row

Applies to: `MonitoredScriptsRow`

The sheet host stays mounted when the status row is empty. So a terminal event
can explain that the selected watch ended, without asserting what happened to
its run. The workspace design shows its watches as pills in
`WorkspaceStatusPillsRow` and keeps only this host (`showsRow` is false).

### 3. One watch opens the sheet; several collapse into a menu

Applies to: `ScriptWatchPills`

One watch opens its details sheet directly. Several watches collapse into a
counted menu that opens the same sheet.

### 4. Watch rows do not animate

Applies to: `MonitoredScriptsRow.body`, `ScriptWatchPills.body`

The rows disable animation with a transaction. There is no movement or
countdown animation, including under Reduce Motion.

### 5. Fixtures can pin the clock

Applies to: `EnvironmentValues.scriptMonitorPresentationDate`, `ScriptMonitorClock`

A `nil` date uses a local presentation clock. Fixtures inject a date without
changing cache state.

### 6. Status pills hug their content

Applies to: `WorkspaceStatusPill`, `WorkspaceStatusPillsLayout`

The capsule is shared by the status pills above the workspace composer. Pills
hug their content so several can share one row. The layout gives every pill an
equal width limit, which keeps short pills compact. The pills stack when their
minimum widths cannot fit. `WorkspaceStatusPillsRow` shows PR monitors first,
then script watches.

### 7. Marquee text scrolls once

Applies to: `MarqueeText`, `MarqueeMotion`

An overflowing line scrolls once to show its end, then returns to its
truncated start. Reduce Motion keeps it truncated. A single pass keeps UI tests
idle afterwards.

1. The timing lives in `MarqueeMotion` because generic types cannot hold static
   stored properties.
2. The animation is declared on the moving text, so a parent's animation reset
   cannot remove it.
3. The deferred reset in `reveal()` returns to the truncated start without
   scrolling back.
