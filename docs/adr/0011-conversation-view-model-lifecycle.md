# ADR-0011: Conversation view model lifecycle, sending, and model catalog

- Status: Accepted
- Recorded: 2026-11-20 (moved from code comments; the decisions are older)
- Applies to: `ConversationViewModel` (`Intent/ViewModels/ConversationViewModel.swift`, `Intent/ViewModels/ConversationViewModel+Lifecycle.swift`, `Intent/ViewModels/ConversationViewModel+Commands.swift`, `Intent/ViewModels/ConversationViewModel+Sending.swift`)
- Related issues: #861

## Context

A conversation screen holds leases on shared stores (agent detail, conversation
store, hooks, monitors). SwiftUI can start its tasks more than once, retained
iPad panes stay mounted out of sight, and connections and catalogs are
invalidated while reads are in flight.

## Decisions

### 1. Local ownership first, one shared load

Applies to: `ConversationViewModel.load()`

Local ownership (the activation generation, the detail lease, the
conversation retain) is installed before independent remote work starts.
Repeated SwiftUI tasks and connected publisher replay share the same load (`loadTask`).

### 2. The new-messages divider is latched per view

Applies to: `ConversationViewModel.load()`, `isEntryScrollReady`

The same retained view keeps its authoritative divider while its live
subscriptions revalidate. A changed store clears the latch. Rendering can start
at the snapshot, but entry positioning waits for the authoritative marker, so a
slow detail read cannot land at a wrong anchor.

### 3. Route validation belongs to the window

Applies to: `ConversationViewModel.validateWorkspaceIfKnown()`

Route validation belongs to this window, never to the shared agent. A stale
route releases only its own lease after authority arrives.

### 4. Covered is not disappeared

Applies to: `ConversationViewModel.conversationCovered()`, `conversationDisappeared()`

A retained iPad pane that leaves sight is covered: its draft and live leases
stay mounted. Only disappearance tears down the live stores.

### 5. Teardown order

Applies to: `ConversationViewModel.teardownLiveStores()`

Teardown synchronously invalidates the screen activation and detaches every
local event handler before captured remote ids are released.

### 6. Refresh rules for agent detail and model catalog

Applies to: `ConversationViewModel.loadCurrentDetail(refresh:)`, `loadModelCatalog(refresh:)`

A connection change has already invalidated shared detail, so no refresh is
requested. A catalog invalidation on the same connection requires explicit
revalidation. A delayed catalog task must reuse the reconnect's bootstrap even
after its reply has settled; it refreshes only when `modelMetadataEpoch`
matches the current connection epoch.

### 7. Loading start time belongs to the conversation

Applies to: `ConversationViewModel.loadingStartedAt`

`loadingStartedAt` is owned by the conversation, not by a loading stage or a retry attempt.

### 8. Transcript rows and queued messages

Applies to: `ConversationViewModel.filteredMessages`, `queuedMessages`

- Event-notification wakes render as a compact event-wake banner. Agent-to-agent
  sends (`metadata.type == "agent_message"`) render with a sender attribution
  header (FE parity: `ChatPanel.svelte`, `ChatMessage.svelte`). `MessageView`
  owns all automated-row rendering.
- `queuedMessages` is a display-only filter: only user-authored entries show.
  Daemon-originated wakes (hook, PR monitor, event notification) and
  agent-to-agent sends are hidden. The store keeps the full queue, and flush behavior is unchanged.

### 9. Suggested prompts never touch the draft

Applies to: `ConversationViewModel.sendSuggestedPrompt(_:)`

A suggested prompt is sent as prompt text only. Unlike `sendMessage`, it never
attaches `pendingImages` and never clears the persisted composer draft; the
in-progress draft (text and attachments) stays intact.

### 10. Send failures are not shown as raw diagnostics

Applies to: `ConversationViewModel` send path (`ConversationViewModel+Sending.swift`)

After a send failure other than an image request error, the retained send
state owns recovery. Raw foreign diagnostics are not UI, so only a generic
"not confirmed" error is logged.

### 11. Photos picker limits

Applies to: `ConversationViewModel.remainingPhotoImageCount`, `photosAllowsVideos`, `photoPickerMaxSelectionCount`

- `remainingPhotoImageCount` is the number of Photos image picks left before the composer reaches its image limit (#861).
- Library videos import as files and never use image slots, so workspace
  conversations keep Photos available for videos once the images are full.
  The chief workspace allows images only.
- Photos treats a selection limit of zero as unlimited, so the image-only limit
  is at least 1. Mixed picks keep the full allowance, and the import rejects
  images beyond the remaining slots.
