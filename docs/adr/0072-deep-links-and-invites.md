# 0072. Deep links and workspace invites

**Status:** Accepted (recorded 2026-11-20 from code comments)

## Context

`intent://` URLs open the app from any web page, not only from the in-app camera scan. A pair link carries a daemon's auth token. An invite link carries an invite secret. A URL can arrive on a cold start, before the app has routed to its first screen.

## Decision

1. **Kinds.** Two kinds are actionable: `intent://pair` (`DeepLinkPairingView`) and `intent://invite`, a shared workspace (`InviteJoinView`). Live Activity `intent://agent` links are routed by `IntentApp` before `handleIncomingURL(_:)`. Every other or malformed URL is ignored without changing app state.
2. **Confirmation.** An actionable link (`DeepLinkRequest`) waits for explicit user confirmation before anything is sent. The sheet shows over whichever screen is current.
3. **Logging.** The URL is never logged.
4. **Cold start.** A URL that arrives before the load has routed is stashed (`stashedDeepLink`) and shown after the load.
5. **Joined invite** (`onInviteJoined(_:workspaceId:)`).
   1. When the window already shows the host, it navigates in place without a reconnect.
   2. Otherwise it switches to the host, then saves the shared workspace as the last screen, so initial routing opens it when the host connects.
   3. Saving the joined login dials the window's own session connection, like a deep-link pairing (`inviteJoinEnvironment(connection:)`).
6. **Identity proof.**
   1. The person's own Mac reads their forge account and publishes or deletes the identity proof, over a dedicated short-lived connection that `close()` drops. It is never a window's session connection.
   2. Only the Mac's owner may publish a proof for that person (`confirmedPrincipal().isOwner`).

## Consequences

- A web page cannot pair a daemon or join a workspace without a user tap.
- Logs never hold pairing tokens or invite secrets.

## Code

- `DeepLinkRequest`
- `AppCoordinator`: `handleIncomingURL(_:)`, `pendingDeepLink`, `onInviteJoined(_:workspaceId:)`, `inviteJoinEnvironment(connection:)`
- `AppCoordinatorRoutingState`: `stashedDeepLink`
- `InviteProofFailure`
