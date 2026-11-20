# ADR-1202: Agent history drawer

- Status: Accepted
- Recorded: 2026-11-20 (moved from code comments; the decisions are older)
- Applies to: `AgentHistoryDrawer`, `OpenAgentHistoryAction`, `EnvironmentValues.isAgentHistoryOpen` (`Intent/Views/Agents/AgentHistoryDrawer.swift`), `AgentHistoryList` (`Intent/Views/Agents/AgentHistoryList.swift`), `AgentHistoryRow`, `AgentHistoryRowSnapshot` (`Intent/Views/Agents/AgentHistoryRow.swift`)

## Context

`AgentHistoryDrawer` is a global right-edge drawer that lists visited agents on
every saved device. It is the counterpart of the workspace list's left-edge
Connections switcher.

## Decisions

### 1. The Connections switcher stands down while agent history is open

Applies to: `EnvironmentValues.isAgentHistoryOpen`

The drawer publishes `isAgentHistoryOpen` so the Connections switcher does not
reveal while agent history is open.

### 2. The open action stores state, not a closure

Applies to: `OpenAgentHistoryAction`

`OpenAgentHistoryAction` stores the drawer's binding and enabled flag rather
than an environment closure, because a closure cannot be compared.

### 3. Only the panel reads the live stores

Applies to: `AgentHistoryList`

`AgentHistoryList` reads the live stores itself, so their updates re-render only
this panel.

### 4. Rows are snapshots prepared before SwiftUI's async row callback

Applies to: `AgentHistoryList.rowList(_:)`, `AgentHistoryRowSnapshot`, `AgentHistoryRow`

`AgentHistoryRowSnapshot` holds values read from the live stores before the rows
are handed to SwiftUI's renderer. `rowList(_:)` resolves environment values and
actions before SwiftUI's async row callback. Constructing an `AgentHistoryRow`
does not build its label or resolve live store state. See ADR-1203.

### 5. Titles and subtitles

Applies to: `AgentHistoryList.workspaceTitle(for:)`, `AgentHistoryList.subtitle(for:showsAgentName:)`

The open device's workspace title is read live. Other devices use the title
stored with the visit. The subtitle is device, then agent. When the workspace is
unknown, the agent name moves to the title instead.
