# ADR-1404: Demo fixture responses mirror the daemon and wait on response gates

- Status: Accepted
- Recorded: 2026-11-20 (moved from code comments; the decisions are older)
- Applies to: `DemoFixtures` (`Intent/Demo/DemoFixtures.swift`, `Intent/Demo/DemoFixturesHistory.swift`, `Intent/Demo/DemoFixturesConversationStartup.swift`, `Intent/Demo/DemoFixturesAssistant.swift`)
- Related issues: #272, #338, #446, intent-hq/intent#3868

## Context

`DemoFixtures` answers every demo JSON-RPC request with static data. UI tests
need some responses to arrive late, at a moment they choose, so they can
observe loading and recovery states.

## Decisions

### 1. Fixture shapes mirror the daemon's results exactly as the stores parse them

Applies to: `DemoFixtures.response(for:params:snapshotAnchor:)`

Examples: `workspace.list` → `WorkspaceStore.parseWorkspaces`, `note.list` →
`Note.parseNote`, `agent.list` → `AgentSession.parseAgent`. Chat subscriptions
deliver a snapshot. Event feeds acknowledge registrations.

### 2. Gated responses use trigger files, not fixed delays, in UI tests

Applies to: `DemoFixtures.ResponseGate`, `DemoFixtures.longConversationHookListGate`,
`DemoFixtures.longConversationBlockHydrationGate`

`longConversationHookListGate` delays the long transcript's hooks row for
container-resize tests (#272). UI tests release a trigger file after they
observe the transcript, because a fixed delay cannot account for a loaded
simulator. Screenshot flows use the default delay. The metadata/snapshot gates
and the hydration gate are independent of it.

`longConversationBlockHydrationGate` is what `agent.getMessageBlock` for
`longConversationAgentId` waits on: the slow-network hydration of the
slim-truncated tool rows near the end of the long transcript (#338). It has the
same shape as the hooks-row gate: a delay by default, or a trigger file for a
UI test that releases the hydration itself.

`ResponseGate.triggerFile` is served once the file exists and waits
indefinitely otherwise.

### 3. Each test-owned gate holds one response until the test releases it

Applies to: `DemoFixtures.agentGroupResponseGate(for:params:arguments:)`,
`DemoFixtures.workspaceProviderGate(from:)`

The loading UI test releases the agent-group response only after it observes
the loading state. `workspaceProviderGate` holds workspace policy validation
until the UI test releases it (#446). Without the argument, ordinary demo
requests still answer at once.

### 4. A sent message is acknowledged without a reply

Applies to: `DemoFixtures.sendMessageResponse(params:)`

Static transcripts have no replying agent. The send is acknowledged without
replacing its optimistic row or ending the Thinking state.

### 5. The status image is generated in memory

Applies to: `DemoFixtures.statusImageWorkspaceId`, `DemoFixtures.statusImageAssetId`,
`DemoFixtures.statusImagePNG`

`demo-ws-dark-mode` ("Dark mode for settings screens") is the one workspace
whose `workspace.list` row carries a `statusImageAssetId`. It has no agents, so
its row opens the detail header rather than a conversation.
`note.readAsset` answers that asset id with `statusImagePNG`
(intent-hq/intent#3868). The PNG is rendered once per process: a mock
"settings in dark mode" screenshot (16:9), so the fixture needs no bundled
image file.

### 6. Timestamps use two anchors

Applies to: `DemoFixtures.iso(minutesAgo:)`, `DemoFixtures.transcriptIso(minutesAgo:)`

Non-transcript labels and future events share each response's snapshot time.
Transcript timestamps are relative to the process-stable message anchor, so
independently rebuilt snapshots preserve immutable message identity.

### 7. History pages are opt-in and shaped to test chained loading

Applies to: `DemoFixtures.usesHistoryPages`, `DemoFixtures.historyMessage(_:)`

`--demo-history-pages` gives varied-height pages with deterministic transport
gates. Ordinary demo and screenshot fixtures stay intact. The middle page is
short enough to stay in the prefetch band after insertion, which exercises
chained loading without another scroll gesture.

### 8. The startup transcript is uniform and its snapshot can be withheld

Applies to: `DemoFixtures.startupTranscriptRequested(by:)`,
`DemoFixtures.startupSnapshotIsHeld(for:params:arguments:)`

The startup transcript uses uniform rows to isolate entry positioning from tool
hydration and footer resizing. Only explicit UI-test launches use this long
unread transcript. The fixture withholds snapshots, not ACKs, to demonstrate
receiving and timeout/retry feedback. Once the trigger file exists, the next
subscription serves its snapshot.

### 9. The Assistant list gate exercises the real Assistant flow

Applies to: `DemoFixtures.assistantListGate(for:params:)`

It exercises the Assistant's real loading, retry, and first-conversation flow.
