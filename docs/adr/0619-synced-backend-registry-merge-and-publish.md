# ADR-0619: iCloud-synced backend registry: read, merge, and publish

- Status: Accepted
- Recorded: 2026-11-20 (moved from code comments; the decisions are older)
- Applies to: `SyncedBackendRecord`, `SyncedBackendPayload`, `SyncedBackendRegistry`, `SyncedKeychainListOutcome`, `SyncedKeychainListing` (`Intent/Services/SyncedBackendRegistry.swift`), `SyncedBackendConnectionMerge`, `SyncedBackendMergeOutcome` (`Intent/Services/SyncedBackendConnectionMerge.swift`), `SyncedBackendPublisher`, `SyncedKeychainWriting` (`Intent/Services/SyncedBackendPublisher.swift`)
- Related issues: ios#251, ios#265, ios#341

## Context

The app shares an iCloud-synced backend registry with the desktop app's
keychain helper (cloudlands-fe `keychain-sync.ts` and `sync-helper.swift`).
There is one generic-password item per backend, under the fixed service
`com.cloudlands.intent.backends`, in the cross-app shared access group. Items
are keyed by the normalized `host:port` account and carry a versioned JSON
payload. `SyncedBackendRegistry` reads it, `SyncedBackendConnectionMerge`
merges it into saved connections, and `SyncedBackendPublisher` writes local
edits back.

## Decisions

### 1. Reads are fail-soft and never mean "no items"

Applies to: `SyncedBackendRegistry`, `SyncedBackendRegistryList`,
`SyncedBackendRegistryUnavailability`, `SyncedKeychainListOutcome`

1. Any SecItem failure, including entitlement rejection, surfaces as
   `.unavailable`, never as "no items". Existing knowledge is then kept as is.
   `.available` (possibly empty) is a trustworthy listing.
2. `SyncedKeychainListOutcome.notFound` (`errSecItemNotFound`) is a successful
   empty read. Every other failure means "keychain state unknown" and must
   never be treated as "no items".
3. `accessGroupUnresolved`: the team-prefixed shared access group could not be
   resolved (`AppIdentifierPrefix` missing from Info.plist).
   `keychainError`: `SecItemCopyMatching` failed, including
   `errSecMissingEntitlement` / `errSecNotAvailable` on builds whose profile
   lacks the shared group.
4. `SyncedKeychainListing` abstracts `SecItemCopyMatching` list queries so
   tests run hermetically (SecItem calls fail in headless CI simulators) and
   can assert the exact query attributes. Tests inject the seam and an explicit
   access group.

### 2. Access group and query

Applies to: `SyncedBackendRegistry.service`, `SyncedBackendRegistry.sharedAccessGroupSuffix`,
`SyncedBackendRegistry.resolveSharedAccessGroup(bundle:)`, `SyncedBackendRegistry.listQuery(accessGroup:)`

1. `service` is fixed and mirrors cloudlands-fe.
2. The full shared access group is TEAMID-prefixed, for example
   `ABCDE12345.dev.intentapp.backends`.
3. iOS has no public entitlement introspection (the Mac helper uses
   `SecTaskCopyValueForEntitlement`), so the team prefix comes from
   Info.plist's `AppIdentifierPrefix` key, which the build expands from
   `$(AppIdentifierPrefix)`.
4. The list query mirrors the desktop helper's `baseQuery` plus list
   attributes, scoped to the shared access group. Items are only ever written
   with `kSecAttrSynchronizable = true`; matching "any" is for robustness.
   Accessibility is set by the publisher on writes, not restricted by the read
   query.

### 3. The record is not Codable

Applies to: `SyncedBackendRecord`

The record is the decoded keychain payload. It is not `Codable` on purpose:
the wire contract lives in `SyncedBackendPayload.parse` (typeof-faithful,
versioned, defaulting). A synthesized encoder or decoder would emit no `v` and
skip every contract rule, so it must never exist as a tempting round-trip path.

Field meanings:

1. `host` is the primary remote host or IP (identity, with `port`). `hosts`
   are candidate hosts, primary first.
2. `token` is the bearer token, always `""` on tombstones. Tombstones keep the
   identity fields.
3. `updatedAt` is the last-writer-wins conflict clock, in ms since the epoch.
4. `deleted` marks a tombstone: the backend was forgotten on some machine.
   `deletedAt` is when the tombstone was written (ms since the epoch).
5. `tcAddress` is an opaque, case-sensitive tunnel route. Missing, null, or
   blank values mean unknown, not an instruction to erase a locally learned
   route.

### 4. Identity and conflict rules mirror the desktop reconcile

Applies to: `SyncedBackendRecord.registryKey`, `SyncedBackendRecord.accountKey`,
`SyncedBackendRecord.wins(over:)`, `SyncedBackendRecord.isExpiredTombstone(now:)`,
`SyncedBackendRegistry.listBackends(now:)`, `SyncedBackendRegistry.listLiveBackends(now:)`

1. `registryKey` is the canonical dedupe identity: the normalized cert
   fingerprint (trimmed, uppercased) when present, else the normalized
   `host:port` (host trimmed and lowercased), the same normalization as the
   desktop reconcile. It is prefixed so a colon-separated fingerprint can never
   collide with a `host:port` key.
2. `accountKey` mirrors the fe's `accountKeyFor`. It is the deterministic
   live/live tie-breaker, matching reconcile's `account > match.account`.
3. `wins(over:)` mirrors the fe reconcile's conflict rules, so every device
   converges on the same survivor regardless of keychain row order: a strictly
   newer `updatedAt` wins; on an equal clock a tombstone beats a live record
   (an address change must not dodge a delete); an equal-clock live/live (or
   tombstone/tombstone) tie breaks by the larger normalized account key.
4. The tombstone TTL mirrors the desktop reconcile's `TOMBSTONE_TTL_MS` (about
   30 days). The desktop purges expired tombstones from the keychain, so a
   straggler item that the purge has not reached yet must not still act as a
   delete here. `deletedAt`, falling back to `updatedAt`, anchors the TTL, the
   same as the fe's `isExpiredTombstone`.
5. `listBackends` returns all key-winning records. Malformed, newer-version,
   and expired-tombstone items are skipped. Records that share a `registryKey`
   collapse to a single winner (`wins(over:)`), so a machine whose address
   changed never appears twice and row order never changes the outcome. It
   includes winning unexpired tombstones, because the merge into saved
   connections must act on them.
6. `listLiveBackends` is `listBackends()` minus tombstones. A tombstone that
   wins its key hides the older live copies.

### 5. The payload parser mirrors the desktop `parsePayload`

Applies to: `SyncedBackendPayload`

1. The parser mirrors the desktop `parsePayload` rules exactly: unknown fields
   are tolerated, items written by a newer app version are reported (and
   skipped by the registry) instead of misparsed, and tombstone tokens are
   always scrubbed. It never throws.
2. `version` is the payload schema version this app understands. It mirrors
   `KEYCHAIN_PAYLOAD_VERSION` in cloudlands-fe.
3. `number` accepts a JSON number, never a JSON bool. JSONSerialization
   bridges both to `NSNumber`, and the wire contract's `typeof x === "number"`
   must reject booleans. `NSNumber` is required for the `CFBoolean` identity
   check, because a Swift numeric cast also accepts booleans; this is why the
   `legacy_objc_type` lint rule is disabled there. `bool` uses the same
   identity check so numeric JSON values are never treated as booleans.
4. Versions compare as `Double`, because the fe compares `v` numerically:
   `v: 1.5` must count as newer than 1, never truncate to 1.
5. `integer` accepts only an exact integer. A fractional `port` is rejected as
   invalid instead of silently truncated, because the fe would key the account
   by the literal number, so truncation misstates identity.

### 6. Merge into saved connections

Applies to: `SyncedBackendConnectionMerge.merge(records:into:now:)`, `SyncedBackendConnectionMerge.Result`

1. iOS has no opt-out. Every live registry record with a cert fingerprint
   appears as a saved connection. A newer remote copy overwrites the local
   fields (last writer wins on `updatedAt`). A tombstone removes the matching
   local connection.
2. Absence is not deletion. Local-only connections that predate sync are never
   removed just because the registry does not list them; the write-back path
   pushes them to the registry instead.
3. `records` are the registry's per-key winners, including tombstones. `now`
   stamps `pairedAt` on newly added connections. The result keeps the existing
   order and appends new records in registry order.
4. A fingerprint-less record is never auto-added. Without a pinned cert the
   transport refuses to connect (ios#251), so the record could only surface as
   a re-pair prompt for a host this device never trusted. Existing
   fingerprint-less locals were paired by the user on this device, and the
   `host:port` fallback can still update them.
5. Tombstone guard: the local copy wins when its clock is strictly newer than
   the tombstone. Equal clocks delete (the fe's tie rule). A local that never
   synced has no registry clock, so its pairing time stands in: a stale
   tombstone written before the user re-paired this machine must not delete
   the fresh pairing.
6. `mergeLive`: a pending direct re-pair protects its new credentials even
   before publication. Otherwise only newer shared clocks replace local fields,
   except for the missing-route upgrade below.
7. `addingRoute` is an additive-field upgrade for records imported before iOS
   read `tcAddress`. Equal clocks authorize learning the missing route only,
   not replacing credentials, metadata, or the shared clock.
8. `apply` rewrites the local copy with the newer remote fields and keeps the
   record identity, pairing date, and connection history. Remote hosts come
   first (primary route), and locally learned extra routes are kept. The shared
   owner row supplies no identity, so only the classification previously
   verified on this device (`principal`) is kept; live authority still comes
   from admission of the current socket.

### 7. Matching a record to a local connection

Applies to: `SyncedBackendConnectionMerge.matchIndex(for:in:)`, `SyncedBackendConnectionMerge.normalizeFingerprint(_:)`

The cert fingerprint is matched first; it is the canonical identity and
survives host and port changes. Then `host:port` overlap is matched among
locals that carry no fingerprint (connections paired before fingerprint
capture). A local with a different fingerprint at the same address is never
matched, because that is another machine reusing the IP.
`normalizeFingerprint` uses the same normalization as `registryKey`.

### 8. Hosts from the registry are untrusted

Applies to: `SyncedBackendConnectionMerge.candidateHosts(of:)`,
`SyncedBackendConnectionMerge.usableHost(_:)`, `SyncedBackendConnectionMerge.isValidNameOrIPv4(_:)`

1. Candidate hosts are the primary `host` first, then the rest of `hosts`,
   keeping only hosts usable in a WebSocket URL and bracket-normalizing raw
   IPv6 literals, then deduped. Validation runs before dedup, so
   `2001:DB8::1` and `[2001:db8::1]` collapse to one route, and an unusable
   primary (for example padded with spaces) never masks a usable spelling of
   the same host. Registry strings are untrusted input, so a malformed host
   must never survive the merge.
2. A tunnel-only publisher uses its opaque route as the required v1 host
   identity. That value must not become a DNS candidate.
3. `usableHost` returns the URL-embeddable form, or nil. It accepts a
   structurally valid DNS name or IPv4 address, or an IPv6 literal. Raw IPv6
   strings (intentd's `pairing_hosts` advertises unbracketed `2001:db8::1`
   forms) are bracket-normalized. Anything else is rejected. This is a
   deterministic allowlist on purpose, because the lenient URL parser in iOS
   17+ would percent-encode junk instead of failing, which hides the problem
   until connect. Spelling is preserved (`MAC.Local` stays as entered);
   callers dedup on `normalizeHost`.
4. An IPv6 literal (bare or bracketed) must be hex digits and colons only, and
   structurally valid: the character allowlist alone admits `::::`.
5. The DNS limits follow the RFC 1035 presentation form (ios#341). A DNS name
   is dot-separated labels of 1–63 ASCII letters, digits, hyphens, or
   underscores (underscores stay allowed for local names such as
   `my-mac_2.local`), with no label starting or ending with a hyphen and no
   empty label (so no leading, trailing, or doubled dot), and at most 253
   characters. A string of only digits and dots is an IPv4 literal and must be
   a dotted quad with octets 0–255 and no leading zeros.

### 9. Display name follows the desktop convention

Applies to: `SyncedBackendConnectionMerge.displayName(for:)`

The record label already is "hostname, fallback host:port". A blank label falls
back to the raw hostname, then `host:port`.

### 10. Merge outcome

Applies to: `SyncedBackendMergeOutcome` (returned by `PersistenceManager.mergeSyncedBackends`)

1. `removedActiveConnection` is true when a tombstone removed the active
   connection. The caller must disconnect and route away from it.
2. `registryReadError` means a prerequisite read or migration failed, and no
   merge or removal was committed.
3. `registryUndecodable` is true when the merge was skipped because the
   saved-connections blob exists but could not be decoded. Nothing was written,
   so the original blob is preserved (intent-hq/ios#265).

### 11. Publishing local edits

Applies to: `SyncedBackendPublisher`, `SyncedKeychainWriting`

1. The publisher publishes only durably saved local edits. It uses the raw
   shared dictionary as the base, so desktop-owned and future v1 fields
   survive a re-pair. The shared registry stays last-writer-wins; iCloud
   supplies no cross-device compare-and-swap.
2. Duplicate adds are retried from a fresh read. They must never fall through
   to an unconditional overwrite.
3. `production()`: only the app's shared persistence opts into real
   publication. Test managers must inject their writer; demo and preview
   stores stay local.
4. `pairingClock(for:)`: a deliberate pairing may supersede a removal already
   observed at the time of that action. Clock skew and same-millisecond
   re-pairs cannot make that edit older than its known predecessor. A retry
   never calls this; it uses the clock saved atomically with the new token.
5. `publish(_:)` is one bounded attempt. Failures keep the pending edit for a
   later foreground pass, including across process restarts.
6. `publish` includes expired tombstones when it finds the winner: an old
   local pairing must not revive a deletion just because its reader-side TTL
   elapsed.
7. Unreadable or newer-schema rows for this identity freeze publication, and a
   different certificate reusing the same `host:port` is never replaced.
8. `acknowledges`: an equal clock alone is not proof that this device wrote
   the row. Only equivalent connection fields acknowledge a failed local save;
   a competing edit must still reach the ordinary importer and live cache.
9. `publishRoutes(_:)`: automatic route observations patch a live row only.
   They cannot add a missing or deleted backend, or restamp stale credentials
   over newer edits. Host-only edits must not restamp a stale tunnel
   observation (`selectedRoute`): a winning shared tunnel is kept while newly
   learned hosts are still published.
10. `write` reads the rows again right before the mutation, to catch local
    concurrent writers and keep edits that landed during preparation.
    `sameRows` compares only account and bytes; keychain row order and
    modification-date attributes are not part of the payload.
11. `readRows` returns nil for an unknown registry and an empty array for a
    successful empty read.
