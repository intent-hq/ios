# ADR-0511: GitHub repo store: session cache, single-page reads, and branch listings

- Status: Accepted
- Recorded: 2026-11-20 (moved from code comments; the decisions are older)
- Applies to: `GitHubRepoStore` (`Intent/Services/GitHubRepoStore.swift`, `Intent/Services/GitHubRepoStore+Branches.swift`)

## Context

`GitHubRepoStore` is the GitHub repo data layer for the repo and branch pickers
(PROTOCOL §5.27). It reads through `repo.list`, `github.authStatus`,
`github.repos.list`, `github.repos.search`, `github.repos.get`,
`github.branches.list`, and `github.branches.listCached` over the shared JSON-RPC
connection, and it calls `repo.warmCache`.

## Decisions

### 1. Every read is a single page

Applies to: `pageLimit`, `ownReposLimit`, `branchesLimit`, `fetchOwnRepos()`, `fetchRemoteBranches(owner:repo:prefix:)`

All reads are single-page, so the pickers render after one round-trip.
Server-side search covers anything beyond the first page.

- `pageLimit` (100) is the page size for `github.repos.search` (§5.27 default
  50, max 200).
- `github.repos.list` is deliberately not paginated (`ownReposLimit`, 50): the
  picker shows recents first and blends in only the first page of GitHub repos
  below.
- `github.branches.list` is deliberately not paginated (`branchesLimit`, 50):
  the branch picker pins the default branch on top and prefix search covers the
  rest. `prefix` narrows the list server-side and is omitted when nil or blank.
  The read throws on transport failure, so callers can tell "no branches" from
  an error.

### 2. Session-lifetime, stale-while-revalidate cache

Applies to: `loadIfNeeded(force:)`, `startLoad(silent:)`, `cacheState`, `isLoading`, `hasLoaded`

`BackendSession` owns the cache for the session. This is FE github-repos slice
parity.

- Cold (nothing cached): `loadIfNeeded` awaits the load with `isLoading` set; a
  concurrent call joins the in-flight load (single-flight).
- Cached and `force == false`: it returns at once and revalidates in the
  background without touching `isLoading` or the cached lists. A failed refresh
  keeps the stale lists.
- `force == true`: it refetches, awaited, silent when a cache exists.
- `isLoading` is true while a cold load is in flight or during a search.
  Background revalidation never sets it, and finishing a search never clears a
  concurrent cold load. `fetchOwnRepos` does not drive it; `loadIfNeeded` does.
- `hasLoaded` is true once a load completed without a transport error. A failed
  load leaves it false, so the next `loadIfNeeded()` retries as a cold load (FE
  parity: an errored load is retried explicitly, not skipped).

### 3. The load generation drops superseded work

Applies to: `loadGeneration`, `invalidate()`, `runLoad(silent:generation:)`

`invalidate()` bumps `loadGeneration`. A load captures it on start, and every
write after an await is dropped once it no longer matches, so a completion from
before an invalidation cannot repopulate the cache. It is observable, so an open
branch step can reload and re-warm its repo after the reconnect clear even when
it held no listing yet. A task may first run after an `invalidate()` that
superseded it; it then touches nothing, because an `isLoading` set there would
never be cleared.

`invalidate()` drops every cached list and the auth and loaded markers, so the
next `loadIfNeeded()` runs cold. A load in flight is superseded: its completion
is dropped and it is no longer joined, so the next call starts a fresh flight.
Branch state (listing, paint, error), in-flight branch loads, and the
warmed-repo set are dropped the same way.

### 4. A reconnect hard-clears and reloads cold

Applies to: `onConnected()`, `hasAttemptedLoad`

The daemon may have changed underneath the cache. A reconnect hard-clears it and
reloads cold, so stale lists never stay visible across a connection flap, and a
pre-reconnect load is neither joined nor applied. A failed load counts too: its
recents and error are stale as well. `hasAttemptedLoad` is true from the first
`loadIfNeeded()` or `loadBranchListing` until `invalidate()`, whether that load
is in flight, succeeded, or failed. With no load ever requested there is nothing
to re-warm until the picker asks.

### 5. Load order and failure

Applies to: `runLoad(silent:generation:)`, `fetchRecentRepos()`

Recents come from the daemon registry with no GitHub round-trip, so they are
fetched concurrently with the auth-gated GitHub list and render before
`github.repos.list` answers. A transport error on the auth read fails the load:
cached auth and lists stay as they were, and a cold load is retried next time.

`repo.list` is the daemon's known-repo registry, MRU-first (PROTOCOL §5.11).
Entries without an `owner` are skipped because they cannot be addressed as
GitHub repos; the MRU order is kept. Errors and malformed responses leave
`recentRepos` unchanged. A failed `github.repos.list` returns false and leaves
`ownRepos` unchanged, so a background refresh keeps the cached page.

### 6. Auth status is tri-state

Applies to: `fetchAuthStatus()`, `fetchAuthStatus(generation:)`, `hasCheckedAuth`

The picker only needs `isConfigured`. The read returns the fetched value, or nil
on a transport error or a superseded read; false is an authoritative
unconfigured result. This is why `discouraged_optional_boolean` is suppressed. A
nil result leaves `isConfigured` untouched, so a failed background refresh
cannot turn a cached, connected picker into not-connected guidance.
`hasCheckedAuth` becomes true once a `github.authStatus` read succeeded, so the
picker does not flash not-connected guidance while auth is unknown. A transport
error never sets it, nor clears a cached value.

### 7. Search results are not stored

Applies to: `searchRepos(query:)`, `rewriteSearchQuery(_:)`

`github.repos.search` returns one page of global repo search. It returns the
parsed results instead of storing them: search results are per-picker view
state, and this store is shared session-wide. The debounced caller publishes the
results and the query they answer together after its own cancellation check;
otherwise out-of-order responses would let an older request overwrite a newer
one's results.

`rewriteSearchQuery` rewrites raw input into GitHub `/search/repositories`
syntax, in parity with the daemon and FE `build_repo_search_query`:
`owner/name` → `name user:owner`, `owner/` → `user:owner`, `/name` → `name`,
and bare text stays unchanged.

### 8. Branch listings

Applies to: `branchStates`, `branchState(owner:repo:)`, `cachedBranchListing(owner:repo:)`, `loadBranchListing(owner:repo:defaultBranch:)`, `branchLoadTasks`

- `branchStates` is keyed by `owner/repo`. It holds the authoritative listing
  (filled only by `loadBranchListing`, so a repo the picker already visited
  renders synchronously on the next visit), the cached-first paint, and the
  cold-load error. It is store-owned, so no sheet keeps a local snapshot that a
  reconnect clear or another sheet's load cannot reach.
- `branchState` is empty (loading) until a load has been asked for.
  `cachedBranchListing` returns nil when the branch step must load.
- `loadBranchListing` loads the repo's default branch (`defaultBranch` when the
  picker already knows it, else `github.repos.get`) plus the first page of
  `github.branches.list`, and publishes it in `branchStates`. It is
  single-flight per repo (`branchLoadTasks`). A completion from before an
  `invalidate()` is returned but not published. On a cold load (no listing yet)
  it clears the error, paints the daemon's local cache as soon as it answers,
  and on failure publishes the error for every consumer. A failed refresh keeps
  the cached listing and stays silent. It throws so a direct caller can react
  too.

### 9. The cached-first paint never becomes authority

Applies to: `paintCachedBranches(owner:repo:key:generation:)`, `fetchCachedBranches(owner:repo:)`

`github.branches.listCached` reads the daemon's local repo cache (or its
one-shot `ls-remote` fallback) for a first paint before the authoritative read
lands. It is never an error authority: a transport failure, a `-32601` from an
older daemon, or an empty listing all read as a cache miss (nil). It is never
promoted to `listing`. The paint is published only while the same generation is
still waiting on the authoritative read (no listing, no error yet), so a late
answer from before a reconnect or after the authoritative outcome cannot land.

### 10. Default branch lookup

Applies to: `fetchDefaultBranch(owner:repo:)`

`github.repos.get` resolves a repo's `defaultBranch` when the list or search DTO
omitted it; global-search results often do. Errors and `{ repo: null }` return
nil.

### 11. Repo cache warming is fire-and-forget

Applies to: `warmRepoCache(owner:repo:)`, `warmedRepos`

`repo.warmCache` refreshes the daemon's repo cache so the later
`workspace.create` hydrates from a fresh cache (PROTOCOL §5.11). Every failure
(a warm already in flight, `-32601` on an older daemon, offline) is only
logged. Each repo is warmed at most once per session (FE `RepoCacheWarmer`
parity: at most once per warmer lifetime). The returned task (nil when
deduplicated) lets tests await completion; callers need not keep it.

### 12. Test-visible task handles

Applies to: `latestLoadTask`, `latestConnectionTask`, `latestBranchPaintTask`

They are kept after `invalidate()` so a test can await superseded work's real
completion. The store never reads them.
