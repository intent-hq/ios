# 0043. Shared view chrome and desktop-parity components

**Status:** Accepted (recorded 2026-11-20 from code comments)

## Context

Some small components appear on many screens: the workspace subtitle under navigation titles, toasts, list load failures, task status icons and progress rings, repo owner avatars, and the Settings surface. Several of them copy a desktop component, and several behave differently on iOS 26, older iOS and visionOS.

## Decision

1. **Workspace subtitle.**
   1. The subtitle is the workspace title. When the workspace is unknown or its title is blank, the subtitle is hidden. It never shows a placeholder.
   2. On iOS 26 and later, the subtitle uses the native `navigationSubtitle`. On iOS 18–25 and on visionOS, where `navigationSubtitle` is not available, a `.principal` toolbar item draws the title over the subtitle and visually replaces the inline title.
   3. The view's `navigationTitle` stays on both paths, for back-button labels and accessibility. The `title` passed to `workspaceNavigationSubtitle(title:workspaceId:)` must match it.
   4. On visionOS the principal item sits leading-aligned next to the back button, so both lines are leading-aligned.
   5. The modifier never branches on whether a subtitle exists. The unfolded Duo's vertical size class can flip while the user types, and a branch swap would remount the focused composer.
   6. On a cold start or deep link, the modifier fetches workspaces if the store has none.
2. **Toasts.**
   1. Light mode uses frosted Liquid Glass, so the banner separates from light content. Dark mode keeps the thin material, which already contrasts.
   2. Interactive glass gives its own press feedback, so only the material banner dims on press (`ToastButtonStyle.dimsOnPress`).
   3. Light glass washes out the lime outline, so the light-mode completion icon uses the completed-task fill.
3. **Load failure.** When a list's first read fails, the list shows `LoadFailureView` with Retry, not an endless loading placeholder or an empty state (intent-hq/ios#462). A disconnected read-only session shows the usual "available when reconnected" message instead.
4. **Task status visuals.**
   1. `TaskStatusIconView` matches the desktop `TaskStatusIcon.svelte`. All geometry is in the desktop 24×24 viewBox and scales to `size`. Cancelled has no inner fill and draws a diagonal line. In progress adds an inner ring (r 10, width 2) and fills the right half from x = 11.52 (48%).
   2. Waiting draws a clock in the outline circle. This is a deliberate iOS addition; the desktop draws waiting like not started.
   3. `TaskStatusIconView.Palette.amber` is also the warning color of conflict relation chips (desktop `text-warning`).
   4. `TaskProgressRingView` matches the desktop NotesPanel ring: a muted track, a green arc for complete, then a blue arc for in progress. Arcs start at 12 o'clock and run clockwise.
   5. Task status and progress geometry is pinned left-to-right. RTL layout must not mirror the half fill or the arcs.
5. **Repo owner avatar.** `RepoOwnerAvatarView` loads `https://github.com/{owner}.png`. It shows a folder icon while loading and when the owner is unknown or the image fails. This matches the desktop `RepoSelector`.
6. **Settings surface.**
   1. Settings does not change the app-wide theme.
   2. Settings keeps the real system status bar and its light/dark contrast. It does not draw a status bar and does not force the rest of Settings into dark mode. A non-fullscreen Settings presentation captures the status-bar appearance (`modalPresentationCapturesStatusBarAppearance`), else it keeps the presenting screen's style.
   3. The diagnostic export list keeps native list button styles. Only navigation uses Intent button chrome.
   4. Acknowledgements reproduce each dependency's license text in full, as the licenses require for binary distribution.

## Code

- `WorkspaceSubtitleResolver`: `subtitle(forWorkspaceId:in:)`
- `WorkspaceNavigationSubtitleModifier`, `NavigationTitleSubtitleView`, `workspaceNavigationSubtitle(title:workspaceId:)`
- `ToastBackground`, `ToastButtonStyle`, `ToastView`
- `LoadFailureView`
- `TaskStatusIconView`, `TaskStatusIconView.Palette`, `TaskProgressRingView`
- `RepoOwnerAvatarView`: `avatarURL(for:)`
- `SettingsStyle`, `SettingsView`, `DiagnosticExportView`, `AcknowledgementsView`
