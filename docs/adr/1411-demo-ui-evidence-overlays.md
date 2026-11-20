# ADR-1411: UI evidence overlays are opt-in and passive

- Status: Accepted
- Recorded: 2026-11-20 (moved from code comments; the decisions are older)
- Applies to: `DemoToastOverlay` (`Intent/Demo/DemoFixturesNavigation.swift`), `DemoIPadPaneGeometry`, `DemoIPadProducerVisibility`, `DemoProducerInspector` (`Intent/Demo/DemoIPadProducerVisibility.swift`)

## Context

Some UI evidence cannot come from the normal demo flow: a toast that has no
backend to route it, and iPad pane geometry that the accessibility tree reports
wrongly.

## Decisions

### 1. The demo toast is held in place for evidence

Applies to: `DemoToastOverlay`

With `--demo-toast` only, it holds an agent-completion toast in the app's toast
position for UI evidence. The demo window has no backend, so the routed toast
would never present there. A tap opens the agent as a real toast or
notification does, before any workspace list read.

### 2. Pane geometry is reported by the pane itself through a one-point marker

Applies to: `DemoIPadPaneGeometry`

The pane lays out the view itself, so tests do not mistake a virtual
accessibility container's window-sized frame for the visible panel. It is
enabled only by a dedicated demo launch argument and never participates in hit
testing. Only a one-point marker enters the accessibility tree, because a
pane-sized element changes XCTest's hit testing of the controls that the test
needs to exercise.

### 3. Native reports are passive

Applies to: `DemoIPadPaneGeometry.NativeReport`, `DemoProducerInspector`

The report is passive diagnostics only: no forced layout, responder changes, or
visibility writes. The inspector reads the existing native hierarchy without
rewriting its visibility or editor binding.

### 4. The list pane keeps covered content visible

Applies to: `DemoIPadProducerVisibility.listPane`

Covered focus keeps the same rendered pane. Only the inherited visibility
changes.
