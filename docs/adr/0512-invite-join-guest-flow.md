# ADR-0512: Joining by invite: the guest connection, identity proof, and join flow

- Status: Accepted
- Recorded: 2026-11-20 (moved from code comments; the decisions are older)
- Applies to: `InviteIdentity`, `InvitePin`, `InvitePreview`, `InviteCredential`, `InviteProof`, `InviteFailure`, `InviteTransport`, `InviteClient`, `InviteSocket` (`Intent/Services/InviteConnection.swift`), `InviteOwnDaemon`, `InviteAccount`, `InviteProofFailure`, `InviteIdentityProof` (`Intent/Services/InviteIdentityProof.swift`), `InviteJoinEnvironment`, `InviteJoinConfirmation`, `InviteJoinProblem`, `InviteJoinModel` (`Intent/Services/InviteJoinFlow.swift`)

## Context

An `intent://invite` link lets a person join a host's workspace, or the host
itself, as a guest. The app talks to the host's unauthenticated `/invite`
endpoint (protocol §5.48 "Joining by invite") and, for a first-time guest, to
the person's own paired Mac to prove a forge account.

## Decisions

### 1. The `/invite` endpoint and what may be logged

Applies to: `InviteClient`, `InviteSocket`, `InviteFailure`, `InviteSocket.response(to:in:)`

The guest side serves exactly `invite.inspect`, `invite.accept`,
`invite.challenge`, and `invite.prove`, with no hello. Every request carries the
invite secret, so request and response text is never logged. Server-authored
error text is dropped: only the documented `error.data.code` values
(`InviteFailure.documentedCodes`) leave `InviteConnection.swift`.
`InviteFailure` reduces failures to bounded codes that are safe to log and show.
`.refused` holds a documented `/invite` refusal code, or an empty string for any
other error. `response(to:in:)` returns the result of the response numbered
`id`, nil for any other frame, and keeps only the documented `error.data.code`
from errors.

### 2. Wire validation never repairs

Applies to: `InviteIdentity.parse(_:)`, `InvitePreview.parse(_:scope:requiresNonce:)`, `InviteCredential`

`InviteIdentity` names a forge account by its stable id
(`{ provider, host, externalUserId }`). `parse` validates the canonical wire
form and never repairs it. `InviteCredential` comes from `invite.prove` or
`invite.accept`: the person's credential for this host, returned once.

### 3. Pin states

Applies to: `InvitePin`

- `pinned`: the invite requires this forge account.
- `unknown`: the host omitted `pinIdentity` (an older host), so the requirement
  is unknown.
- `unpinned`: an explicit `null`; anyone with the link may join.

### 4. Preview fields

Applies to: `InvitePreview`, `InvitePreview.describesSameInvite(as:)`

The preview comes from `invite.inspect` or `invite.challenge` and feeds the
consent prompt. `hostName` is the host's display name: collaboration name, then
pretty hostname, then plain hostname. `nonce` is set on `invite.challenge` only:
the single-use nonce the proof must carry. A refreshed challenge may change only
its nonce.

### 5. Host scope and timeouts

Applies to: `InviteClient.credentials`, `InviteClient.proveTimeout`

A host join sends `scope: "host"` on every call (§5.49). Omission means
workspace scope, so workspace links keep the legacy shape. `invite.prove` gets a
longer timeout (60 s against 30 s) because the host reads the proof back from
the forge before it answers.

### 6. Transport

Applies to: `InviteTransport`, `InviteSocket`

`InviteTransport` is one JSON-RPC call over an open `/invite` socket, abstracted
for tests. `routeLabel` is the display label of the route that answered (a host,
or the tunnel). `InviteSocket` is a pin-verified `/invite` WebSocket, dialed
over the link's direct hosts (legacy links only) and its Tailcat tunnel.

### 7. The identity proof runs on the person's own Mac

Applies to: `InviteOwnDaemon`, `InviteIdentityProof.publish(_:nonce:hostLabel:on:)`, `InviteProof`

The person's own daemon is a Mac this phone is paired to as its owner. A
first-time guest proves a forge account by having that daemon publish the
host's nonce under the account (protocol §5.48 "The identity proof"). The forge
token never leaves the Mac. `InviteOwnDaemon` is abstracted for tests. The proof
is a GitHub gist, or a snippet on a GitLab instance. A proof is never accepted
for an account the person did not confirm: a mismatched login or provider
deletes the proof and fails with `accountChanged` (the Mac published under a
different account than the one confirmed).

- `supportsCollaborationIdentity` (`collaborationIdentity: 1`): the separate
  `identity.*` sign-in exists (§5.49).
- `supportsIdentitySeam`: protocol 10.8+ serves GitLab proofs
  (`sourceControl.identityProof.*`).

### 8. Which account proves

Applies to: `InviteIdentityProof.account(for:on:)`, `anyAccount(on:)`, `InviteAccount`

`account(for:on:)` returns the account to prove for the pin, or nil when none is
signed in.

- A Mac with the separate collaboration sign-in proves only with it. Falling back
  to repository credentials is forbidden (§5.49), so a missing collaboration
  account means signing in there.
- An explicitly unpinned invite uses the person's selected identity (Settings),
  or any connected account when none is selected yet.
- With no requirement (an older host), GitHub comes first, then the Mac's GitLab
  connection.
- `InviteAccount.externalUserId` is known when the account was matched by stable
  id. `collaboration` means it was read through the separate collaboration
  sign-in (`identity.*`).

### 9. Account read failures

Applies to: `githubUser(on:)`, `gitlabStatus(params:on:)`, `failure(_:provider:)`, `InviteProofFailure`

`githubUser` returns empty when GitHub is not connected; a rate limit is neither
and throws. `gitlabStatus` returns empty when the status cannot be read; a rate
limit throws. `failure` maps the daemon's documented proof refusals
(`error.data.code`) and returns `unavailable` for anything else.
`InviteProofFailure` holds these bounded reasons: `missingScope` means the
account lacks the permission a proof needs (`gist` or `api`); `unsupported`
means the Mac is too old for the invite's GitLab requirement.

### 10. Proof cleanup

Applies to: `InviteIdentityProof.delete(_:collaboration:on:)`, `InviteJoinModel.proveOnOwnMac(preview:client:saved:)`

Deletion is best effort: the proof is spent once the host has read it. After a
successful prove the flow is past the point of no return: the host minted the
credential and the proof is spent. The proof is removed before saving, because
saving dials the new host.

### 11. Wire helpers

Applies to: `InviteIdentityProof.target(provider:host:)`, `stableId(_:)`, `maximumSafeInteger`

GitHub's `host` param is omitted; other providers name their instance.
`stableId` returns a forge account id as the canonical string; GitHub sends a
number. `maximumSafeInteger` is the largest integer a JSON number carries
exactly (2^53 - 1).

### 12. The join flow mirrors the desktop

Applies to: `InviteJoinModel`, `InviteJoinEnvironment`

`InviteJoinModel` drives one `intent://invite` join and mirrors the desktop flow
(cloudlands-fe `invite-deep-link.ts`). A returning guest presents the login this
device already has for the host. A first-time guest proves a GitHub or GitLab
account through their own paired Mac. The result is saved as an invited session
(synced to the person's other devices) and opened.

`InviteJoinEnvironment` holds what the join needs from the app: the host
transport, saved connections, the person's own Mac, and how to save and open the
result. It is injected so the flow is testable without sockets or persistence.
`saveCredential` persists a new credential as an invited session (PairingFlow)
and returns its record. `open` routes this window to the connection, opening the
workspace id when set.

### 13. Join decisions

Applies to: `InviteJoinModel.join(over:)`, `accept(as:preview:client:)`, `prove(_:challenge:)`, `start()`, `answer(_:)`

- If the person owns this host, there is nothing to join; the flow opens it.
- Only the confirmed person may join. When the host no longer knows a returning
  guest's login (`accept` returns false on `credential-invalid`), the flow falls
  through to the proof, which asks again.
- `prove` publishes and proves with one fresh challenge when the host found the
  proof stale. There is no new prompt, because consent stands.
- The flow accepts no credential and publishes or proves no identity before
  the person confirms (`InviteJoinConfirmation`). Before that it only reads from
  the host: `join(over:)` fetches the preview with `client.inspect()`, and
  `proveOnOwnMac` fetches a challenge with `client.challenge()`. `existingAccess` is a login this device already
  holds (`invite.accept`); `proveOnMac` is a proof published by the person's own
  Mac (`invite.prove`). `answer(true)` confirms and `answer(false)` declines.
- `start()` starts the join, or restarts it after a failure.
- A cancellation means the sheet was dismissed, so nothing is shown.
- `needsOwnMac`: this device has no own Mac to make the identity proof.
  `needsSignIn`: the own Mac has no GitHub or GitLab account signed in for this
  invite. `InviteJoinProblem.retryable` says whether trying again could help,
  which offers Try Again.
