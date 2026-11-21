# ADR-0208: Workspace tool fixtures stay opt-in and test-friendly

- Status: Accepted
- Recorded: 2026-11-20 (moved from code comments; the decisions are older)
- Applies to: `DemoBrowserFixtures` (`Intent/Demo/DemoBrowserFixtures.swift`), `DemoChangesFixtures` (`Intent/Demo/DemoChangesFixtures.swift`), `DemoTerminalFixtures` (`Intent/Demo/DemoTerminalFixtures.swift`), `DemoAgentListFixtures` (`Intent/Demo/DemoAgentListFixtures.swift`), `DemoSharingFixtures` (`Intent/Demo/DemoSharingFixtures.swift`)

## Context

These fixtures answer the browser, script, changes, terminal, agent list, and
invite RPCs of the demo workspaces.

## Decisions

### 1. Script responses have a separate entry point

Applies to: `DemoBrowserFixtures.scriptResponse(for:params:longList:)`

The separate entry point keeps the launch fixture testable without process
arguments.

### 2. Long-list scripts start as completed runs

Applies to: `DemoBrowserFixtures.initialRuntime(scriptId:longList:)`

Completed runs make the opt-in rows visible without changing the default demo.

### 3. Large diffs are measurable and need horizontal scrolling

Applies to: `DemoChangesFixtures.largeDiffLineCount`, `DemoChangesFixtures.largeDiffSource(lineCount:prefix:)`,
`DemoChangesFixtures.largeDiffPatternLength`

`--demo-large-diff=<n>` (for example `2000`) sets the changed lines in every
demo file diff, for measuring large diffs. Each run of six lines is three
context lines, one deletion, and two additions. The source has a long line every
25 lines so that horizontal scrolling matters.

### 4. The terminal buffer sets a steady cursor

Applies to: `DemoTerminalFixtures.buffer`

A steady cursor lets UI automation reach idle while real keyboard interactions
still work.

### 5. The agent list is scope-aware, and counts describe the whole workspace

Applies to: `DemoAgentListFixtures.response(rows:params:)`

It is an in-memory `agent.list` endpoint shared by the ordinary demos and the
grouping scenario. Counts always describe the whole workspace, whatever scope
is requested.

### 6. Invite links exercise the Share sheet without a host

Applies to: `DemoSharingFixtures.response(for:params:)`

With `--demo-data`, `workspace.invite.create` returns a fresh link that expires
in a week and is single-use when pinned to a login.
