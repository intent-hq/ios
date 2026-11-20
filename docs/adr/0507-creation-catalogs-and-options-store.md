# ADR-0507: Creation catalogs and the creation options store

- Status: Accepted
- Recorded: 2026-11-20 (moved from code comments; the decisions are older)
- Applies to: `CreationCatalog` (`Intent/Services/CreationCatalog.swift`), `CreationOptionsStore` (`Intent/Services/CreationOptionsStore.swift`, `Intent/Services/CreationOptionsStore+Events.swift`)

## Context

The creation picker and the conversation labels both need the specialist list,
the default model provider, and per-provider model lists. `CreationCatalog` is
a shared cache for one such list. `CreationOptionsStore` owns the catalogs for a
backend and invalidates them on events and connection changes.

## Decisions

### 1. One catalog per backend, owned by the cache

Applies to: `CreationCatalog`

There is one backend-local catalog per list. A successful empty value is warm.
A read is owned by the cache, so cancelling one caller cannot cancel another
caller's RPC. `value` is optional on purpose: nil means no successful read, and
an empty array is a successfully loaded catalog. `CreationOptionsStore.models(for:)`
returns nil for the same reason: a missing provider catalog stays distinct from
a loaded empty one. This is why `discouraged_optional_collection` is suppressed
on both.

### 2. Picker refreshes and label ensures differ

Applies to: `CreationCatalog.ensure(force:consumer:)`, `CreationOptionsStore.loadIfNeeded(force:consumer:)`, `loadModelsIfNeeded(providerId:force:consumer:)`, `ensureSpecialists(consumer:)`, `ensureModels(providerId:consumer:)`

- Explicit picker refreshes bypass freshness but join an existing read. Label
  ensures never launch a silent read behind a valid cache hit.
- Explicit creation-picker entry and refresh keep stale-while-revalidate. Label
  consumers call `ensureSpecialists` or `ensureModels` instead.
- User-opened pickers still revalidate warm model catalogs. Concurrent callers
  share that revalidation; the automatic label path never calls
  `loadModelsIfNeeded`.
- `BackendSession` owns the shared catalogs. Conversation label ensures are
  independent of the creation picker's explicit provider and auth refreshes.
- `loadPhase` is the explicit picker load. A silent revalidation of a loaded
  catalog stays `.loaded`, so the picker never shows a spinner over cached
  lists.

### 3. Invalidation bursts share one trailing read

Applies to: `CreationCatalog.invalidate(refresh:)`, `CreationCatalog.read(_:)`

Bursts during one flight share at most one trailing read. If that read is
invalidated too, the cache stays stale for the next ensure or event.

### 4. Resets

Applies to: `CreationCatalog.reset(clear:releaseConsumers:)`, `CreationOptionsStore.reset()`, `CreationCatalog.retireFlight()`

Hard resets and backend teardown clear labels. A connection transition can keep
the last good value while it rejects every pre-transition reply.
`CreationOptionsStore.reset()` releases all session observers and interests
before disconnecting. A transport callback that was already sent lives until
its reply, timeout, or disconnect. It cannot publish or launch a follow-up
after its flight retires, so only an unsent flight task is cancelled.

### 5. Leases are local; one listener invalidates caches

Applies to: `CreationOptionsStore.retainSpecialists(consumer:)`, `observeSession()`

These local leases never register a daemon feed. The single session listener
also invalidates idle caches, so a later view can reuse only data that has not
changed while it was away.

### 6. Feed readiness bumps catalog revisions

Applies to: `CreationOptionsStore.observeGlobalFeed()`

Reads before the global subscription ACK cannot cover changes missed while the
feed was unavailable. Catalog revisions are bumped, so even a late pre-ACK
response must reconcile before it becomes fresh again. Idle caches only expire;
the initial already-ready replay and repeated readiness never add reads or
provider discovery.

### 7. Specialist changes expire the whole backend roster

Applies to: `CreationOptionsStore.handleCatalogEvent(_:)`

`specialist.list` has no workspace parameter. Any workspace's
`specialists:changed` event expires this backend's roster.

### 8. Store identity and provider data

Applies to: `CreationOptionsStore.loadGeneration`, `workspaceProviderOptions`, `fetchProviders(generation:identity:)`, `specialistCatalog`

- `loadGeneration` is connection and reset identity only. Catalog events must
  not force `agent.get`.
- `workspaceProviderOptions` is host enablement for workspace and agent
  creation. Conversation model menus can still load catalogs for existing agents
  on disabled providers.
- `host.providerAuthStatus` (PROTOCOL §5.14): `authenticated` is tri-state
  (true, false, nil unknown). On a transport error the read returns false and
  leaves `providers` unchanged.
- Specialist labels historically accepted a missing description, so a missing
  `description` is decoded as an empty string.

### 9. Test-only task handles

Applies to: `CreationCatalog.latestReadTask`, `CreationOptionsStore.latestLoadTask`, `CreationOptionsStore.latestCreationRefreshTask`

Each keeps the most recently started task after its owner drops it, so tests can
await a superseded read's or load's real completion, or the reconnect
revalidation spawned for an open creation picker. Production code never reads
them.
