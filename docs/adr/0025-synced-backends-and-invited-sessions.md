# 0025. Synced backends and invited sessions

**Status:** Accepted (recorded 2026-11-20 from code comments)

## Context

Saved daemon connections and invited sessions sync to the person's other devices through the Keychain, using the same Security seam as the desktop app (§5.49). Rows can be removed on one device while another is offline or locked.

## Decision

1. **Joining by invite.** `InviteJoinModel` mirrors the desktop flow (cloudlands-fe `invite-deep-link.ts`). A returning guest presents the login this device already has for the host. A first-time guest proves a GitHub or GitLab account through their own paired Mac. The result is saved as an invited session, synced to the person's other devices, and opened.
   1. If the person owns the host, there is nothing to join.
   2. Only the confirmed person may join. If the host no longer knows the saved login, the flow falls through to the proof, which asks again.
   3. A stale proof gets one fresh challenge without a new prompt; consent stands.
   4. After the host mints the credential, the proof is spent. It is deleted before saving, because saving dials the new host.
2. **Invited session registry.**
   1. `InvitedSessionRegistry` is the desktop invited-session service, with the same access group as owner sync. Its v2 dispatch never changes owner v1.
   2. Both groups must be readable before any migration or live publication.
   3. Removal insertion is create-only. The duplicate path never updates a row; equal known fields acknowledge it and unknown bytes stay. The account hashes every immutable field, so re-derivation proves equality without rewriting unknown fields.
   4. A legacy-group copy is cleaned up only after the destination save.
3. **Records and keys.** `InvitedSyncRecord` keeps raw fields across rewrites; a parser rejection freezes the original bytes. `InvitedSyncKey` uses the §5.49 byte encoding and compares UTF-8 bytes, because Swift `String` equality normalizes Unicode.
4. **Removal journal.** `InvitedSyncJournal` is a token-free removal memory and outbox beside the backend journal. It is saved before credential writes, so a locked Keychain cannot undo a forget. `pendingLegacy` holds only hashes and provenance, never bearer payloads; absent means no retry exception. An already observed removal also covers a newly bound row.
5. **Legacy migration.** `InvitedLegacyMigrationReceipt` is local, token-free provenance for a row seen before its alias retired. The digest permits only those exact bytes in that access group. A bound person must still authenticate on every retry.
6. **Import outcome.** Known removals stay authoritative even if the final local read fails. An unavailable registry is no evidence of other deletes.

## Code

- `InviteJoinModel`: `start()`, `answer(_:)`, `join()`, `accept(as:preview:client:)`, `prove(_:challenge:)`
- `InvitedSessionRegistry`: `read()`, `insertRemoval(_:)`; `InvitedSyncRecord`, `InvitedSyncKey`, `InvitedSyncJournal`: `pendingLegacy`, `InvitedSyncMerge`, `InvitedLegacyMigrationReceipt`, `InvitedImportOutcome`
