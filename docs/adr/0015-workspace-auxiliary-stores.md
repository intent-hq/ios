# 0015. Workspace auxiliary stores

**Status:** Accepted (recorded 2026-11-20 from code comments)

## Context

Several small stores show workspace side data: assistant threads, background hooks, script monitors, PR monitors. They share patterns for loading and event folds.

## Decision

1. **Assistant.**
   1. `AssistantStore` starts observing events on first use, not at init. Every `BackendSession`, including transient pairing sessions, owns one, and most never open the Assistant tab.
   2. A failed refresh keeps the threads and the failure message. A shown failure stays (banner and spinner together) until the read ends.
   3. The history read walks every page. Threads ascend by creation, so the newest are on the last page.
2. **Background hooks (§5.40, §6.5).**
   1. `runNow(hookId:)` only acknowledges. The run's outcome arrives as `hook:*` events. `cancel(hookId:)` relies on the `hook:cancelled` event to drop the hook.
   2. `foldHookEvent(…)` is a pure fold, like the FE `foldHookEvent`. Terminal events drop the hook.
   3. An event for an unknown hook sets `needsRefetch`. The fold cannot invent wire fields such as `delayMs` or `createdAt`.
   4. An event with `nextRunAt` keeps the hook scheduled. Without it, a terminal dispatched or evicted event follows and drops it.

## Code

- `AssistantStore`: `startObservingIfNeeded()`, `refresh()`, `loadPhase`
- `BackgroundHookStore`: `runNow(hookId:)`, `cancel(hookId:)`, `foldHookEvent(…)`, `FoldResult`
