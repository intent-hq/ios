# ADR-0103: Window scene title and activation go through the window's own scene

- Status: Accepted
- Recorded: 2026-11-20 (moved from code comments; the decisions are older)
- Applies to: `WindowSceneTitle` (`Intent/App/WindowSceneTitle.swift`), `WindowSceneActivator`, `WindowSceneReader`, `AppCoordinator.agentSelectionHandler(raising:)` (`Intent/App/WindowSceneActivator.swift`)

## Context

On iPad and visionOS a window shows the backend's label as its scene title, and
a notification tap must bring the right window forward. Both act on the
`UIWindowScene` that hosts the view.

## Decisions

### 1. The title view is outside navigation and session identity

Applies to: `WindowSceneTitle`

`WindowSceneTitle` publishes the backend label through its own scene. It is
kept outside navigation and session identities so Home and rebinds update the
same anchor.

### 2. Reattachment republishes; transient removal does not clear

Applies to: `WindowSceneTitle.TitleView.didMoveToWindow()`

A transient removal from the window does not need to erase the last published
title. Reattachment publishes the latest value to the new scene.

### 3. Reassert the server label after SwiftUI writes

Applies to: `WindowSceneTitle.TitleView.observeTitle()`, `applyTitle()`

SwiftUI reflects primary navigation titles into `UIScene.title`. The view
observes `UIScene.title` and reasserts the server label after those writes,
leaving in-app navigation titles untouched. `applyTitle()` writes only when the
value differs; this equality check prevents feedback loops.

### 4. Raise by scene session, not by `openWindow(value:)`

Applies to: `WindowSceneActivator`, `WindowSceneReader`

`WindowSceneActivator` brings the window's own scene forward with
`activateSceneSession`. Raising with `openWindow(value:)` is unreliable: a
window switched to another backend in place keeps the scene value it was
created with, so raising by its current backend can open a duplicate window.
`WindowSceneReader` feeds the hosting scene to the activator.

### 5. No-op for the active window

Applies to: `WindowSceneActivator.raiseIfNeeded()`, `AppCoordinator.agentSelectionHandler(raising:)`

`raiseIfNeeded()` does nothing for the window the user is already in,
including a window that just switched backends in place to deliver the
selection. The agent-selection handler raises the window where several windows
exist and then navigates it to the selected agent.
