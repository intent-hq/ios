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
7. **Synced backend registry (shared with the desktop keychain helper).**
   1. One generic-password item per backend under service `com.cloudlands.intent.backends` in the TEAMID-prefixed shared access group, keyed by normalized `host:port`, carrying a versioned JSON payload (cloudlands-fe `keychain-sync.ts`, `sync-helper.swift`). iOS has no entitlement introspection, so the team prefix comes from Info.plist `AppIdentifierPrefix`.
   2. Reads are fail-soft. `errSecItemNotFound` is a successful empty read. Any other failure, including a missing entitlement, is `unavailable`, never "no items", and existing knowledge stays. The list query mirrors the desktop helper's `baseQuery`; items are written synchronizable, and the query matches any for robustness.
   3. `SyncedBackendRecord` is deliberately not `Codable`. The wire contract lives in `SyncedBackendPayload.parse`, which mirrors desktop `parsePayload`: unknown fields are tolerated, newer-version items are reported and skipped, tombstone tokens are always scrubbed, and it never throws. `version` mirrors `KEYCHAIN_PAYLOAD_VERSION`. Numbers are JSON numbers, never booleans (checked through `CFBoolean` identity), compared as `Double` so `v: 1.5` is newer than 1. A fractional `port` is invalid, not truncated.
   4. `updatedAt` is the last-writer-wins clock in ms. Tombstones keep identity fields with an empty token. A missing or blank `tcAddress` means unknown, not "erase the learned route".
   5. `registryKey` is the normalized fingerprint (trimmed, uppercased) when present, else normalized `host:port`, with a prefix so the two can never collide. `accountKey` mirrors FE `accountKeyFor`.
   6. `wins(over:)` mirrors the FE reconcile so every device picks the same survivor: newer `updatedAt` wins; on equal clocks a tombstone beats a live record (an address change must not dodge a delete); other ties go to the larger account key.
   7. Tombstones expire after about 30 days (`tombstoneTTLMs`, FE `TOMBSTONE_TTL_MS`), anchored on `deletedAt`, else `updatedAt`. `listBackends(now:)` skips malformed, newer-version and expired items and collapses each key to one winner, including unexpired tombstones. `listLiveBackends(now:)` drops tombstones.
8. **Merge into saved connections (`SyncedBackendConnectionMerge`).**
   1. iOS has no opt-out. Every live record with a fingerprint appears as a saved connection. A fingerprint-less record is never auto-added: the transport refuses unpinned connections (ios#251), so it could only be a re-pair prompt for a host this device never trusted. Existing fingerprint-less locals can still be updated through the `host:port` fallback.
   2. A newer remote copy overwrites local fields. Existing order is kept and new records are appended in registry order. A tombstone removes the matching local connection unless the local clock is strictly newer (equal clocks delete, the FE tie rule). A local that never synced uses its pairing time as its clock, so a stale tombstone cannot delete a fresh re-pair. Absence is not deletion; local-only connections are pushed to the registry instead.
   3. `matchIndex(…)` matches by fingerprint first, then `host:port` among locals without a fingerprint. A local with a different fingerprint at the same address is another machine and never matches.
   4. A pending direct re-pair protects its new credentials before publication. Otherwise only newer clocks replace fields, except `addingRoute`: an equal clock may add a missing `tcAddress` to a record imported before iOS read it, without replacing credentials or the clock.
   5. `candidateHosts(of:)` puts the primary first, validates before dedup (so spellings of one IPv6 host collapse and a padded primary cannot mask a good one), and bracket-normalizes IPv6. Registry strings are untrusted and `raceHosts` force-unwraps URLs, so a malformed host never survives. A tunnel-only publisher's opaque route is never a DNS candidate.
   6. `usableHost(_:)` is a deterministic allowlist: a structurally valid DNS name, IPv4 dotted quad (no leading zeros, octets 0–255), or IPv6 literal. iOS 17+ URL parsing is lenient and would hide junk until connect. Labels allow underscores for local names (ios#341). Spelling is kept; callers dedup on `normalizeHost`.
   7. `apply` keeps record identity, pairing date and history; remote hosts come first and learned routes stay. The shared owner row supplies no identity; only the principal classification verified on this device is kept, and authority still comes from socket admission. `displayName(for:)` follows the desktop label convention.
   8. A removed active connection makes the caller disconnect and route away. An undecodable saved-connections blob skips the merge and writes nothing (intent-hq/ios#265).
9. **Publication (`SyncedBackendPublisher`).**
   1. Only durably saved local edits are published, on top of the raw shared dictionary, so desktop-owned and future fields survive. The registry is last-writer-wins; iCloud has no cross-device compare-and-swap. Only the app's shared persistence publishes; test managers inject a writer and demo stores stay local.
   2. Duplicate adds retry from a fresh read and never fall through to an overwrite. Rows are re-read just before mutation to catch local concurrent writers. Signatures compare only account and bytes.
   3. `pairingClock(for:)` lets a deliberate pairing supersede a removal already observed, even with clock skew or a same-millisecond re-pair. A retry uses the clock saved with the new token.
   4. `publish(_:)` makes one bounded attempt; a failure keeps the pending edit for a later foreground pass, across restarts. Expired tombstones still block an old pairing from reviving a deletion. Unreadable or newer-schema rows for the identity are frozen, and a different certificate at the same `host:port` is never replaced.
   5. `publishRoutes(_:)` patches a live row only; it cannot add a missing backend or restamp stale credentials. Host-only edits keep a winning shared tunnel address.
   6. An equal clock is not proof this device wrote a row. Only equivalent fields acknowledge a failed local save (`acknowledges`).

## Code

- `InviteJoinModel`: `start()`, `answer(_:)`, `join()`, `accept(as:preview:client:)`, `prove(_:challenge:)`
- `SyncedBackendRegistry`: `listBackends(now:)`, `listLiveBackends(now:)`, `listQuery(accessGroup:)`, `resolveSharedAccessGroup(bundle:)`; `SyncedBackendRecord`: `registryKey`, `accountKey`, `wins(over:)`, `isExpiredTombstone(now:)`, `tombstoneTTLMs`; `SyncedBackendPayload`: `parse`, `version`; `SyncedKeychainListOutcome`
- `SyncedBackendConnectionMerge`: `merge(…)`, `mergeLive(_:into:)`, `addingRoute(_:to:)`, `matchIndex(…)`, `candidateHosts(of:)`, `usableHost(_:)`, `displayName(for:)`; `SyncedBackendMergeOutcome`
- `SyncedBackendPublisher`: `production()`, `pairingClock(for:)`, `publish(_:)`, `publishRoutes(_:)`, `acknowledges(_:record:clock:)`, `signatures(_:)`; `SyncedKeychainWriting`
- `InvitedSessionRegistry`: `read()`, `insertRemoval(_:)`; `InvitedSyncRecord`, `InvitedSyncKey`, `InvitedSyncJournal`: `pendingLegacy`, `InvitedSyncMerge`, `InvitedLegacyMigrationReceipt`, `InvitedImportOutcome`
