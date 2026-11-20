# 0111. UI tests and native controls

**Status:** Accepted (recorded 2026-11-20 from code comments)

## Context

XCTest reports accessibility state that does not always match what a touch does. Native menus, sheets, popovers and selectable text change hit-testing, identifiers and frames between iOS releases.

## Decision

1. **Tap where the touch goes.**
   1. Selectable Markdown text (Textual) covers links in accessibility hit-testing. Tap a link by coordinate inside its frame. For a wrapped link, use the lower-left corner.
   2. Textual draws attachments in a canvas. Tap the attachment region by coordinate.
   3. Native `Menu` wrappers can report non-hittable while a touch opens them. Tap their centre by coordinate.
   4. Native popovers expose `PopoverDismissRegion` instead of a Cancel button, also on iPhone. Tap an exposed strip of the region, not its centre.
   5. Edge-tap tests tap outside the label or icon. A centre tap does not catch a missed edge.
2. **Identifiers.** iOS 27 native submenus drop action identifiers. Match the exact localized label inside the menu, never the toolbar control.
3. **Hittability is not proof.** `isHittable` and snapshot counts do not prove touch delivery or VoiceOver traversal. Observe the state after a gesture. VoiceOver traversal needs separate verification.
4. **Frames.**
   1. Accessibility frames carry rounding. Use a sub-point tolerance (for example `44 - 0.001`), not a geometric tolerance.
   2. iOS 26 floating sheets stay scaled. Recover layout coordinates from the scroll container.
   3. Design checks compare against Figma values, not production layout constants.
5. **Scrolling.**
   1. The default swipe uses the full scroll frame, which extends behind the keyboard and the iPad sidebar. Drag inside the visible part of the owning pane.
   2. A full-speed fling can skip the target. Use bounded loops that correct in both directions.
6. **Settling.** Text input and accessibility values can settle after `typeText` returns. Wait with a predicate expectation. Wait for a growing card to become hittable before a tap.
7. **Cleanup.** An XCTest assertion abort can skip Swift `defer`. Use `addTeardownBlock` for cleanup.
8. **Screenshots.** Take iPad screenshots in portrait. Landscape iPad screenshots come back rotated and cropped. App Store iPad screenshots are the exception and are set to landscape before launch.
9. **Fresh simulators.** Dismiss the SpringBoard notification alert. It dims screenshots and blocks the scene network monitor.

## Consequences

- A test that taps by coordinate states why in its name or in this record, not in a comment.

## Code

- `TurnFailureNoticeUITests`, `InlineResponseImageUITests`, `WorkspaceBrowserUITests`: coordinate link taps
- `ScriptMonitorsUITests`, `WorkspaceComposerUITests`: menu taps by coordinate
- `DiagnosticExportUITests`, `QuestionWizardUITests`: `PopoverDismissRegion`
- `AssistantNavigationUITests`, `WorkspaceScriptUITests`: label matching in submenus
- `IPadFocusInteractionTestSupport`, `IPadSidebarUITests`, `WorkspaceSearchUITests`: hittability and traversal limits
- `ManualConnectionDesignUITests`: `referenceFrame`; `PairingDesignUITests`: sheet scale
- `ConversationMermaidUITests`, `WorkspaceListMenuUITests`: `addTeardownBlock`
- `WorkspaceBackgroundUITests`, `AppStoreScreenshotTests`: orientation
