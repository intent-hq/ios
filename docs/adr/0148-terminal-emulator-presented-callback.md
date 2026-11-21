# ADR-0148: The terminal reports presentation from `viewDidAppear`

- Status: Accepted
- Recorded: 2026-11-20 (moved from code comments; the decisions are older)
- Applies to: `TerminalPresentationObserver` (`Intent/Views/Workspaces/TerminalEmulatorView.swift`)

## Decisions

### 1. `onPresented` runs from a UIKit controller's `viewDidAppear`

Applies to: `TerminalPresentationObserver.Controller.viewDidAppear(_:)`

SwiftUI `onAppear` runs before the cover's presentation animation finishes.
`TerminalPresentationObserver` embeds a UIKit controller and calls
`onPresented` from its `viewDidAppear`, which runs after the animation.
