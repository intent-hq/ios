# 0005. Conversation screen lifecycle and sending

**Status:** Accepted (recorded 2026-11-20 from code comments)

## Context

A conversation screen shares agent detail with other windows and iPad panes. SwiftUI can run `.task` more than once, and publishers replay on connect. A detail read can be slow, and the connection can change during it.

## Decision

1. **Load.**
   1. `load()` installs local ownership before it starts independent remote work. Repeated SwiftUI tasks and connected publisher replays share one load.
   2. `loadingStartedAt` belongs to the conversation, not to one stage or retry.
   3. Route validation belongs to the window, never to the shared agent. A stale route releases only its own lease after authority arrives.
2. **Entry position.**
   1. Rendering can start at the snapshot. Entry positioning waits for the authoritative new-messages marker (`isEntryScrollReady`), so a slow detail read cannot land at a wrong anchor.
   2. A retained view keeps its authoritative divider while its live subscriptions revalidate. A changed store clears the latch.
3. **Teardown.** `teardownLiveStores()` invalidates the activation and detaches every local event handler synchronously, before the captured remote ids are released.
4. **Transcript and queue.**
   1. The transcript shows every message. Event wakes and agent-to-agent sends render as their own row types in `MessageView`.
   2. The queued-messages section shows only user-authored entries. Daemon wakes (hook, PR monitor, event notification) and agent-to-agent sends are hidden. The store keeps the full queue, and flush does not change.
5. **Sending.**
   1. A suggested prompt sends only its text. It never attaches `pendingImages` and never clears the saved draft.
   2. A failed delivery is logged without the foreign error text. The retained message state owns recovery.
   3. `ConversationSendAttempt` is session-local recovery, separate from the replaceable transcript. Its original identity never changes. Selections and placed references stay owned by the attempt until delivery is confirmed (`ConversationSendFileAccess` holds the extra leases). It is not a durable outbox or an idempotency key.
   4. Only a send that failed before dispatch, as proven locally, can be retried (`canRetry`). The daemon auto-queues duplicate ordinary sends; it does not deduplicate them.
6. **Photos picker.**
   1. Library videos import as files and never use image slots. Workspace conversations keep Photos open for videos when the images are full.
   2. Photos treats a limit of zero as unlimited. Mixed picks keep the full allowance, and the import rejects images beyond the remaining slots.

## Code

- `ConversationViewModel`: `load()`, `loadingStartedAt`, `isEntryScrollReady`, `teardownLiveStores()`, `filteredMessages`, `queuedMessages`, `sendSuggestedPrompt(_:)`, `photosAllowsVideos`, `photoPickerMaxSelectionCount`
