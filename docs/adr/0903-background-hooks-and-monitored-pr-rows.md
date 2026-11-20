# ADR-0903: Background hook and monitored PR status rows

- Status: Accepted
- Recorded: 2026-11-20 (moved from code comments; the decisions are older)
- Applies to: `BackgroundHooksRow` (`Intent/Views/Conversation/StatusStrip/BackgroundHooksRow.swift`), `HookTimeBar`, `HookTimeBarView` (`Intent/Views/Conversation/StatusStrip/HookTimeBar.swift`), `MonitoredPrsRow` (`Intent/Views/Conversation/StatusStrip/MonitoredPrsRow.swift`), `AgentWaitingView` (`Intent/Views/Conversation/StatusStrip/AgentWaitingView.swift`)

## Context

The status strip above the composer shows the active agent's background hooks
(PROTOCOL §5.40) and monitored PRs (PROTOCOL §5.42). These rows are the iOS
counterparts of cloudlands-fe's `BackgroundHooksRow` and `MonitoredPrsRow`.

## Decisions

### 1. Background hook row

Applies to: `BackgroundHooksRow`

The row is a faint chip row above the composer. It has one chip per
`scheduled` or `running` hook.

1. A running hook shows a spinner. A scheduled hook shows a thin shrinking
   time-to-next-run bar, derived from `nextRunAt` minus now over `delayMs`. It
   is a local animation, with no daemon polling.
2. Perpetual hooks carry a small repeat glyph.
3. Tapping a chip opens a menu. Its header shows name and state, next run, TTL
   expiry, and last error. The actions are Run now and Cancel hook.
4. The parent hides the row when the agent has no active hooks.
5. iOS shows no code preview, by spec decision.

### 2. Hook menu detail lines mirror the FE hover card

Applies to: `BackgroundHooksRow.detailLines(_:now:)`

The lines are name and state, "next run in …", "expires in …", and the last
run error when present. The relative durations mirror the FE hover card's
`nextRunIn` and `expiresIn` helpers. They are computed against `now` when the
menu renders. A timing line is dropped when its timestamp is absent or cannot
be parsed.

### 3. The hook time bar is a Core Animation layer

Applies to: `HookTimeBar`, `HookTimeBarView`

Core Animation owns the continuous shrink, which avoids per-frame SwiftUI
work. The parent keeps `.id(nextRunAt)` so each new hook cycle gets a fresh
bar. The model value of the bar transform is zero while it animates, so it
stays zero after the animation is removed.

`HookTimeBarView.countdown(nextRunAt:delayMs:now:)` keeps the original
clamping behavior for invalid or out-of-cycle dates.

### 4. Monitored PR row

Applies to: `MonitoredPrsRow`

The row is rendered above the background-hooks row when both exist. It has one
chip per `active` monitor.

1. The label is `#<number>`. It is prefixed with `<owner/repo>: ` only when the
   monitor's repo differs from the workspace repo.
2. An amber dot shows while changes are pending the debounce emit.
3. Tapping a chip opens a menu. Its header shows the last-refresh detail: title,
   repo#number, checks, approvals, and threads summary, mergeable or blocked
   status, last change time, and pending status. The actions are Check and
   flush, Open PR, and Cancel monitor.
4. The parent hides the row when the agent has no active monitors.

### 5. The PR summary line is dropped when it duplicates the title line

Applies to: `MonitoredPrsRow.detailLines(_:now:)`

Without a title or snapshot, the title line falls back to `repo#number`. The
summary line is then equal to the title line and is dropped, so every line is
distinct. "Last change … ago" is relative to `now` when the menu renders.

### 6. Open PR uses the external-link allowlist

Applies to: `MonitoredPrsRow.prUrl(_:)`

The URL is the wire `url` when present, else the canonical GitHub form. The
Open PR action opens it only after it passes the `ExternalLink` http/https
allowlist.

### 7. Menu detail lines use positional IDs

Applies to: `BackgroundHooksRow.hookChip(_:)`, `MonitoredPrsRow.monitorChip(_:)`

The detail lines mirror the FE hover card. They are display strings with no
inherent identity, and `\.self` would collide if two lines matched. So the
`ForEach` uses the offset as the ID.

### 8. Waiting rows are prepared before SwiftUI asks for them

Applies to: `AgentWaitingView.waitingList`

The view snapshots the errors and prepares the row views before SwiftUI
requests rows off the main actor.
