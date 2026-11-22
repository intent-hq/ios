# ADR-0145: Workspace browser page load phase and cross-origin subframes

- Status: Accepted
- Recorded: 2026-11-20 (moved from code comments; the decisions are older)
- Applies to: `WorkspaceBrowserPage` (`Intent/Views/Workspaces/WorkspaceBrowserPage.swift`)

## Decisions

### 1. `loadPhase` tracks the main-frame load

Applies to: `WorkspaceBrowserPage.loadPhase`

`loadPhase` is the main-frame load. A failure replaces the page until the next
load or Reload.

### 2. A failure reported mid-load stays on screen

Applies to: `WorkspaceBrowserPage.webView(_:didFinish:)`, `WorkspaceBrowserPage.reportCrossOriginSubframe()`

`reportCrossOriginSubframe` runs when a subframe asks for a different local
server. When the main frame is still loading, the page keeps its spinner
behind the message until `didFinish`. A failure reported mid-load (a
cross-origin subframe) stays on screen after `didFinish`, so `didFinish` only
moves a plain `loading` phase to `loaded`.
