# 0024. Invites and identity proof

**Status:** Accepted (recorded 2026-11-20 from code comments)

## Context

A guest joins a host's workspace or the host itself through an invite link (protocol §5.48 "Joining by invite", §5.49). The host's `/invite` endpoint is unauthenticated, and every request carries the invite secret. A pinned invite asks the guest to prove a forge account.

## Decision

1. **The `/invite` endpoint.**
   1. It serves exactly `invite.inspect`, `invite.accept`, `invite.challenge` and `invite.prove`, with no hello.
   2. Request and response text is never logged. Server-authored error text is dropped. Only documented `error.data.code` values leave `InviteConnection` (`InviteFailure.refused`).
   3. `InviteSocket` is pin-verified. It dials the link's direct hosts (legacy links only) and its Tailcat tunnel.
   4. A host join sends `scope: "host"` on every call (§5.49). Omission means workspace scope, so workspace links keep the legacy shape.
   5. `invite.prove` waits up to 60 s, because the host reads the proof back from the forge first.
2. **Validation.** `InviteIdentity.parse(_:)` validates the canonical wire form and never repairs it. A preview that does not match its scope is rejected. A refreshed challenge may change only its nonce (`describesSameInvite(as:)`). The credential from `invite.prove`/`invite.accept` is returned once.
3. **Pins.** `InvitePin.unknown`: the host omitted `pinIdentity` (older host). `InvitePin.unpinned`: explicit `null`, anyone with the link may join.
4. **Identity proof.**
   1. The guest's own daemon (a Mac paired as owner) publishes the host's nonce under the forge account. The forge token never leaves the Mac.
   2. A Mac with the separate collaboration sign-in (`collaborationIdentity: 1`) proves only with it. Falling back to repository credentials is forbidden (§5.49); a missing collaboration account means signing in there.
   3. Unpinned invites use the person's selected identity (Settings), else any connected account. With no requirement (older host), GitHub is tried first, then the Mac's GitLab connection.
   4. Never prove an account the person did not confirm. A proof published under another account fails as `accountChanged`.
   5. The proof is deleted after use, best-effort; it is spent once the host has read it.
   6. GitHub targets omit the host parameter; other providers name their instance. Account ids are canonical strings (GitHub sends a number) and must be exact JSON integers.
   7. Only documented proof refusals (`error.data.code`) map to specific `InviteProofFailure` cases; everything else is unavailable.
5. **Creating invite links (`WorkspaceSharingModel`).** The Share sheet creates a link with `workspace.invite.create` (§5.48) that anyone can use, or that one GitHub account can use once, and hands it to the system share sheet. People join only by opening a link; members and open links are managed on the Mac. Links are capabilities: shown and shared on request, never logged.
   1. Protocol 10.8+ hosts take `pinProvider`/`pinHost`. The form names a GitHub account, so the app sends `pinProvider: "github"` and never lets the host pick its own forge. Older hosts resolve pins on GitHub only, which is the same.
   2. A login is trimmed and a leading `@` dropped. Only an `intent://` link is shared.
   3. Expiry text rounds partial days up, so a fresh week-long link reads "7 days"; under a day reads as today.

## Code

- `InviteClient`: `inspect`, `challenge`, `prove`, `accept`; `InviteSocket`, `InviteSocket.response(to:in:)`, `InviteIdentity`, `InvitePin`, `InvitePreview`, `InviteCredential`, `InviteFailure`
- `WorkspaceSharingModel`: `createLink`, `namesPinProvider(protocolVersion:)`, `normalized(_:)`, `inviteLink(from:)`, `expiryText(_:now:)`
- `InviteIdentityProof`: `account(for:on:)`, `publish`, `delete(_:collaboration:on:)`, `anyAccount(on:)`, `failure(_:provider:)`, `stableId(_:)`, `InviteProofFailure`
