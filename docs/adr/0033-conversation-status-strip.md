# 0033. Conversation status strip: hooks, PR monitors and script watches

**Status:** Accepted (recorded 2026-11-20 from code comments)

## Context

Above the composer, the conversation shows the active agent's background hooks (PROTOCOL §5.40), monitored PRs (PROTOCOL §5.42) and script watches. The desktop has the same rows (cloudlands-fe `BackgroundHooksRow`, `MonitoredPrsRow`). The workspace design shows them as pills in one row.

## Decision

1. **Order and visibility.** PR monitors show above background hooks. In the workspace design, `WorkspaceStatusPillsRow` shows PR monitors first, then script watches. The parent hides a row when it has nothing active.
2. **Background hooks (`BackgroundHooksRow`).**
   1. One chip per `scheduled` or `running` hook. A running hook shows a spinner. A scheduled hook shows a shrinking bar from `nextRunAt` and `delayMs`. The bar is a local animation; the app does not poll the daemon. Perpetual hooks show a repeat glyph.
   2. The chip menu shows name and state, next run, TTL expiry and last error, with Run now and Cancel hook. `detailLines(_:now:)` drops a timing line when its timestamp is missing or does not parse.
   3. iOS shows no code preview for a hook (product decision).
   4. `HookTimeBar` lets Core Animation run the shrink, so SwiftUI does no per-frame work. The parent sets `.id(nextRunAt)`, so each cycle gets a fresh bar.
3. **Monitored PRs (`MonitoredPrsRow`).**
   1. One chip per `active` monitor. The label is `#<number>`, with an `owner/repo: ` prefix only when the repo differs from a known workspace repo (`chipLabel(_:workspaceRepo:)`). When the workspace repo is unknown, the label is the bare number. An amber dot shows while changes wait for the debounce emit.
   2. The chip menu shows the last refresh (title, checks, approvals, threads, merge state, last change, pending state) with Check and flush, Open PR and Cancel monitor. A summary line that would repeat the title line is dropped.
   3. Open PR uses the wire `url`, or the GitHub URL as fallback (`prUrl(_:)`), and opens it only through the `ExternalLink` http/https allowlist.
4. **Script watches.**
   1. Watch metadata describes notification triggers. It never states the runtime state of a script (`ScriptMonitorPresentation`).
   2. `MonitoredScriptsRow` keeps its sheet host after the row empties, so a terminal event can say that the watch ended, without a claim about its run.
   3. `ScriptWatchPills`: one watch opens its details sheet directly; several collapse into a counted menu that opens the same sheet.
   4. Script watch rows have no movement or countdown animation, also under Reduce Motion.
5. **Pills.** `MarqueeText` scrolls an overflowing pill once to show the end, then returns to the truncated start. Reduce Motion keeps it truncated. One pass keeps UI tests idle afterwards.

## Consequences

- Status rows never poll the daemon for timing; they animate from the last event.

## Code

- `BackgroundHooksRow`: `detailLines(_:now:)`, `HookTimeBar`
- `MonitoredPrsRow`: `chipLabel(_:workspaceRepo:)`, `prUrl(_:)`, `detailLines(_:now:)`
- `MonitoredScriptsRow`, `ScriptWatchPills`, `ScriptMonitorPresentation`
- `WorkspaceStatusPill`, `WorkspaceStatusPillsRow`, `MarqueeText`
