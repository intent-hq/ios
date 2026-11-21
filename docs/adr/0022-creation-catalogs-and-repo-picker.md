# 0022. Creation catalogs and the GitHub repo picker

**Status:** Accepted (recorded 2026-11-20 from code comments)

## Context

Agent and workspace creation need specialists, providers, models and GitHub repos. Conversations also show model and specialist labels. These catalogs are shared per backend session and must stay fresh without extra reads.

## Decision

1. **Catalog cache (`CreationCatalog`).**
   1. One catalog per backend. A successful empty value is warm. The cache owns each read, so cancelling one caller cannot cancel another's RPC.
   2. Explicit picker refreshes bypass freshness but join an existing read. Label ensures never start a silent read behind a valid cache hit.
   3. Bursts during one flight share at most one trailing read. If that read is invalidated too, the cache stays stale for the next ensure or event.
   4. A hard reset or backend teardown clears values. A connection transition can keep the last good value while it rejects every pre-transition reply.
   5. A sent transport callback lives until reply, timeout or disconnect, but cannot publish or start a follow-up after its flight retires. Only an unsent flight is cancelled.
2. **`CreationOptionsStore`.**
   1. `BackendSession` owns the shared catalogs. Conversation label ensures (`ensureSpecialists`, `ensureModels`) are independent of the picker's explicit provider and auth refreshes. The automatic label path never calls `loadModelsIfNeeded(providerId:force:consumer:)`.
   2. `workspaceProviderOptions` gates creation only. Model menus can still load catalogs for existing agents on disabled providers.
   3. `loadIfNeeded(force:consumer:)` is the explicit picker load with stale-while-revalidate. A silent revalidation of a loaded catalog stays `.loaded`, so the picker never shows a spinner over cached lists. User-opened pickers still revalidate warm catalogs, and concurrent callers share it.
   4. `loadGeneration` is connection and reset identity only. Catalog events must not force `agent.get`.
   5. Specialist labels also accept a missing description, as they always have.
   6. `fetchProviders` reads `host.providerAuthStatus` (PROTOCOL §5.14). A transport error returns false and leaves `providers` unchanged.
3. **Catalog events.**
   1. Leases never register a daemon feed. The single session listener also expires idle caches, so a later view reuses only unchanged data.
   2. Reads before the global feed ACK cannot cover changes missed while the feed was down. On ACK, catalog revisions are bumped so a late pre-ACK reply must reconcile first. Idle caches only expire; the initial ready replay and repeated readiness add no reads.
   3. `specialist.list` has no workspace parameter, so any workspace's specialist change expires the backend's roster.
4. **GitHub repo store (PROTOCOL §5.27).**
   1. All reads are single-page so pickers render after one round-trip. Server-side search covers the rest. `github.repos.list` uses `ownReposLimit` below the recents; `github.branches.list` uses `branchesLimit` with the default branch pinned and prefix search for the rest.
   2. The cache lives for the session (`BackendSession`). The first `loadIfNeeded(force:)` blocks with `isLoading`; later calls return the cache and revalidate silently (FE github-repos parity). A failed refresh keeps stale lists. A failed load leaves `hasLoaded` false, so the next call is cold.
   3. A reconnect hard-clears and reloads cold, so stale lists never survive a connection flap. It re-warms only a cache the picker asked for. `invalidate()` drops lists, auth, branch state, in-flight branch loads and warmed repos, and bumps `loadGeneration`; every write after an await checks it. A task that first runs after an invalidate touches nothing.
   4. `isLoading` is true only for a cold load or a search. Revalidation never sets it, and a finished search never clears a cold load.
   5. `hasCheckedAuth` is true only after a successful `github.authStatus`. A transport error never sets or clears cached auth, so a connected picker never flips to not-connected guidance.
   6. Recents come from `repo.list` (daemon registry, MRU-first, no GitHub round-trip) and load in parallel with the auth-gated list. Entries without an owner are skipped. Errors leave `recentRepos` unchanged.
   7. `searchRepos(query:)` returns results instead of storing them: search is per-picker state, and the debounced caller publishes results with their query after its own cancellation check. `rewriteSearchQuery(_:)` matches daemon/FE `build_repo_search_query` (`owner/name` → `name user:owner`).
   8. `fetchDefaultBranch(owner:repo:)` reads `github.repos.get` when the DTO omits `defaultBranch`. It is best-effort.
5. **Branches.**
   1. `branchStates` is store-owned, keyed by `owner/repo`, so no sheet keeps a local copy that a reconnect or another sheet cannot reach. Only `loadBranchListing` fills a listing, so a visited repo renders synchronously next time. Branch loads are single-flight per repo.
   2. A cold branch load paints `github.branches.listCached` first, only while the same generation still waits on the authoritative read. The cached read is never an error authority: failure, `-32601` or empty all mean a miss, and it is never promoted to `listing`.
   3. A failed cold load publishes the error to every consumer; a failed refresh keeps the listing and stays silent.
   4. `warmRepoCache` sends `repo.warmCache` (PROTOCOL §5.11) at most once per repo per session (FE `RepoCacheWarmer` parity), so a later `workspace.create` hydrates from a fresh cache. Failures are only logged.

## Code

- `CreationCatalog`: `ensure(force:consumer:)`, `invalidate(refresh:)`, `reset(clear:releaseConsumers:)`, `retireFlight`
- `CreationOptionsStore`: `loadIfNeeded(force:consumer:)`, `loadModelsIfNeeded(providerId:force:consumer:)`, `ensureSpecialists`, `ensureModels`, `fetchProviders`, `loadGeneration`, `workspaceProviderOptions`, `retainSpecialists(consumer:)`, `handleCatalogEvent`, `observeGlobalFeed`
- `GitHubRepoStore`: `loadIfNeeded(force:)`, `invalidate()`, `onConnected()`, `startLoad(silent:)`, `fetchAuthStatus`, `fetchRecentRepos`, `fetchOwnRepos`, `searchRepos(query:)`, `fetchDefaultBranch(owner:repo:)`, `branchStates`, `warmedRepos`, `loadBranchListing`, `paintCachedBranches(owner:repo:key:generation:)`, `fetchCachedBranches(owner:repo:)`, `warmRepoCache(owner:repo:)`, `fetchRemoteBranches(owner:repo:prefix:)`, `rewriteSearchQuery(_:)`
