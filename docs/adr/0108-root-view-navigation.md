# ADR-0108: RootView navigation stacks and window-level presentation

- Status: Accepted
- Recorded: 2026-11-20 (moved from code comments; the decisions are older)
- Applies to: `RootView` (`Intent/App/RootView.swift`), `RootNavigationState` (`Intent/App/RootNavigationState.swift`), `RootView.detailContent`, `WorkspaceDetailPlaceholder` (`Intent/App/RootDetailContentView.swift`), `RootView.syncNavigationState()`, `RootView.shouldRepushConversation(currentScreen:pendingAgentId:conversationAgentId:)` (`Intent/App/RootCompactNavigationView.swift`)
- Related issues: #908

## Context

Outside the iPad shell, `RootView` drives a compact `NavigationStack` and a
regular-width `NavigationSplitView` from the coordinator's current screen. It
also presents window-wide overlays: toasts, the read-only state, deep-link
sheets, and the Settings sheet.

## Decisions

### 1. Navigation state is phase enums, not parallel flags

Applies to: `RootNavigationState`

`RootNavigationState` replaced 12 parallel Boolean and empty-string `@State`
properties with mutually exclusive phase enums and typed targets.

- `ConversationPhase.pendingAfterWorkspaceDetail` and
  `CompactNotePhase.pendingAfterWorkspaceDetail`: the workspace detail mounts
  first, and the push happens once `showingWorkspaceDetail` settles.
- `ConversationPhase.repushing`: the regular-width `NavigationStack` is tearing
  down to re-push on the next run-loop tick.

### 2. Only a user back gesture moves `.presented` to `.hidden`

Applies to: `RootView.detailContent` (`onChange(of: navigation.conversationPhase)`)

Only a user-initiated back moves `.presented` to `.hidden` while
`currentScreen` is `.agentConversation`; a programmatic re-push uses
`.repushing`. That transition alone calls `onBackToWorkspaceDetail()`.

### 3. A deferred re-push is dropped when the user moved on

Applies to: `RootView.shouldRepushConversation(currentScreen:pendingAgentId:conversationAgentId:)`

The deferred iPad re-push scheduled by the tear-down and re-push branch in
`syncNavigationState()` happens only while the coordinator still shows the
same conversation. If the user navigated back in the meantime, it is dropped.

### 4. One presenter across the animated branch change

Applies to: `RootView.rootContent`

`rootContent` uses a real container (`ZStack`) to keep one presenter across
the animated branch change. `Group` would distribute its modifiers to both the
outgoing and incoming content, briefly giving each its own overlay window.

### 5. One splash across loading and connecting

Applies to: `RootView.isLaunchSplash`, `RootView.launchContent`

Loading and connecting share one `SplashArtView`. It sits in a stable position
so animation playback does not reset across the phase transition. The phase
views render on top.

### 6. Window-scoped presentation

Applies to: `RootView.body`, `supportsMultipleWindows`, `selectionHandlerToken`, `workspacePresentation`, `composerCoverage`

- `isRemoteReadOnly` is set per window, so a drop on one Mac never disables another window.
- Multi-window tap routing (spec decision 5): `supportsMultipleWindows` is
  false on iPhone, so alert taps there always navigate in place, unchanged.
- On multi-window platforms only the source backend's window renders a toast
  (`windowPresentsAlert`); on iPhone every toast renders. The tap still goes
  through the manager's routing, so delivery lands on the source backend's
  registered handler.
- `selectionHandlerToken` identifies this window's selection-handler
  registration, so disappear removes only this window's registration, never a
  successor's. A pairing window (no backend) registers no handler; taps for a
  backend route to that backend's own window.
- `workspacePresentation` is used at regular width only; the compact list owns its own value.
- `composerCoverage` counts modal layers open in this window and keeps only the foremost chat's composer.

### 7. Global subscription failure is shown

Applies to: `RootView.body` (bottom overlay)

A live socket without its global subscription leaves every store blind to
updates. The bounded retry failure is shown with a Retry action.

### 8. visionOS sounds come from the window's scene

Applies to: `RootView.windowFeedbackEmitter`, `RootView.feedbackEventForThisWindow`

On visionOS the agent-completion chime and the workspace attention cue are
emitted from within this window's scene, not as global system sounds, so
spatial audio places them at the source workspace's window. Other platforms
keep the global sounds. `feedbackEventForThisWindow` uses the same per-window
decision as toast rendering (`windowPresentsAlert`); every other window gets nil.

### 9. Duo and Settings layout

Applies to: `RootView.duoSidebarWidth`, `RootView.workspaceSplitView`, `RootView.workspaceFlowContent`

- The unfolded Duo divides the window at its midpoint, including the trailing
  rail. The content proposal excludes the system rail but the fold does not,
  so the width adds both safe-area insets, halves the total, and subtracts the leading inset.
- The Settings sheet uses `.preferredColorScheme(.dark)` because the system
  status bar sits over the dark backdrop. The content keeps the selected theme.

### 10. Empty detail pane

Applies to: `WorkspaceDetailPlaceholder`

`WorkspaceDetailPlaceholder` is the detail-pane empty state for wide layouts with no workspace selected (#908).
