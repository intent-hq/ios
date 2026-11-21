# ADR-0129: Workspace conversation header

- Status: Accepted
- Recorded: 2026-11-20 (moved from code comments; the decisions are older)
- Applies to: `WorkspacePhoneNavigationModifier`, `WorkspaceConversationHeader`, `WorkspaceNavigationHeader`, `WorkspaceHeaderText`, `WorkspaceTextTrimLayout`, `WorkspaceVerticalConversationHeader` (`Intent/Views/Conversation/Transcript/WorkspaceConversationHeader.swift`)

## Context

Workspace, agent, and Assistant screens show a custom navigation header. It
must work on iPhone, in the iPad shell, and on the Duo with its vertical bar
and contextual rail.

## Decisions

### 1. One header geometry for all navigation

Applies to: `WorkspaceNavigationHeader`

Workspace, agent, and Assistant navigation share the native top safe area and
the same control geometry.

### 2. When the system navigation bar is hidden

Applies to: `WorkspacePhoneNavigationModifier.body(content:)`

Outside the iPad shell, the Duo's vertical toolbar needs the system bar.
Inside the shell, the rail replaces it.

### 3. The header drops titles that a sidebar already shows

Applies to: `WorkspacePhoneNavigationModifier.showsHeaderTitle`,
`WorkspaceConversationHeader.showsTitle`

The iPad shell names the workspace in its sidebar. The header repeats the name
only while that sidebar is collapsed. The sidebar also names the open agent
while its workspace sits there, so the agent header drops its title.

### 4. An empty header collapses on the Duo rail

Applies to: `WorkspaceNavigationHeader.collapsesWhenEmptyOnRail`,
`WorkspaceNavigationHeader.collapsesOnRail`

With its controls on the Duo rail and no copy, the header would only be an
empty band over the content. The workspace overview drops that band.
Conversations keep their spacing.

### 5. Controls stay clear of system chrome

Applies to: `WorkspaceNavigationHeader.windowAdaptedControls`,
`WorkspaceNavigationHeader.controls`

1. In the iPad design, the shell gutter and the header inset keep the controls
   below system chrome.
2. On iOS 26 and later, `containerCornerOffset` reserves only the system's
   actual corner region, including the iPad window controls.
3. In the iPad design without a back button, a clear spacer balances the
   trailing menu, so Assistant titles share the agent alignment.

### 6. Header text measures from cap top to final baseline

Applies to: `WorkspaceHeaderText`, `WorkspaceTextTrimLayout`

Header text is measured from the cap top to the final baseline without
clipping native glyphs or descenders. `WorkspaceTextTrimLayout` is the opt-in
cap-to-baseline measurement for workspace text with native baselines.

### 7. The vertical header's title owns the top inset

Applies to: `WorkspaceVerticalConversationHeader`

The outer display keeps the native rail actions, while its title owns the top
inset.
