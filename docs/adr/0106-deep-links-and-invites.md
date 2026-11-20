# ADR-0106: Deep links and workspace invites need confirmation

- Status: Accepted
- Recorded: 2026-11-20 (moved from code comments; the decisions are older)
- Applies to: `DeepLinkRequest`, `AppCoordinator.handleIncomingURL(_:)`, `onInviteJoined(_:workspaceId:)`, `inviteJoinEnvironment(connection:)`, `OwnMacConnection` (`Intent/App/AppCoordinatorDeepLinks.swift`), `AppCoordinator.pendingDeepLink` (`Intent/App/AppCoordinator.swift`), `RootView` (`Intent/App/RootView.swift`)

## Context

The app handles `intent://` URLs. Any web page can trigger one, so they
cannot act like the in-app camera scan.

## Decisions

### 1. Only two kinds are actionable, each behind a confirmation

Applies to: `DeepLinkRequest`, `AppCoordinator.handleIncomingURL(_:)`, `AppCoordinator.pendingDeepLink`

`IntentApp`'s `onOpenURL` routes Live Activity `intent://agent` links before
`handleIncomingURL`. After that, two kinds are actionable: `intent://pair`
(`DeepLinkPairingView`) and `intent://invite`, a shared workspace
(`InviteJoinView`). Each waits for explicit user confirmation before anything
is sent. `pendingDeepLink` drives the sheet in `RootView`, which is presented
over whichever screen is current (first-run pairing or a connection). Every
other or malformed `intent://` URL is ignored without disturbing app state.

### 2. The URL is never logged

Applies to: `AppCoordinator.handleIncomingURL(_:)`

Pair links carry the auth token and invite links carry the invite secret, so
the URL itself is never logged.

### 3. A cold-start link is stashed

Applies to: `AppCoordinatorRoutingState.stashedDeepLink`

The URL can arrive before `onLoadComplete` has routed to the first screen. It
is stashed and surfaced after load.

### 4. Joining an invite opens the host

Applies to: `AppCoordinator.onInviteJoined(_:workspaceId:)`

When an invite was joined, or the device already had access to the host, the
host opens, landing in the shared workspace when the invite named one.

- When the window already shows this host, it navigates in place with no reconnect.
- Otherwise initial routing restores the saved `workspaceDetail` screen once
  the host connects. The screen is saved after the switch, because the switch
  starts that host at its list.

### 5. Saving a joined login uses the window's session connection

Applies to: `AppCoordinator.inviteJoinEnvironment(connection:)`, `OwnMacConnection`

Saving dials the window's own session connection, exactly like a deep-link
pairing. `OwnMacConnection` is the person's own Mac, used to read their forge
account and to publish and delete the identity proof. It uses a dedicated
short-lived connection that `close()` drops, never a window's session
connection. Only the Mac's owner may publish a proof for this person: `open`
throws `InviteProofFailure.unavailable` otherwise. Requests time out after 60 seconds.
