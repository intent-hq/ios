# 0105. GitHub repo and branch caches

**Status:** Accepted (recorded 2026-11-20 from test comments)

## Context

The workspace creation pickers show GitHub repos and branches. One `GitHubRepoStore` serves every picker on a session. Lists must open fast on a second visit, but they must never show data from before an invalidation or a reconnect, and a transient failure must not turn a working picker into "not connected" guidance.

## Decision

1. **Stale while revalidate.** `loadIfNeeded()` returns at once with a cached list and refreshes in the background. The background refresh never shows the cold spinner, and its result lands in place. Concurrent callers share one flight (ios#308).
2. **Auth state.**
   1. A failed auth read leaves auth unknown, not "not configured". The picker shows no not-connected guidance, and the load does not count as complete; the next call retries as a cold load.
   2. A transport failure on the auth read never flips a cached picker to not-connected guidance and never drops its lists. This also holds for the silent revalidation on a cached reopen.
3. **Invalidate and reconnect.**
   1. A refresh superseded by `invalidate()` or a reconnect never repopulates the cache and never marks it loaded. The next call starts a new cold load instead of joining the superseded flight.
   2. A refresh task that has not started yet when `invalidate()` runs exits at entry without reads.
   3. A reconnect hard-clears the cache, including a partial cache from a failed cold load, and retries. Stale lists are gone before the reload answers; the picker shows the cold spinner.
4. **Search.** Search results go back to the caller (per-view state) and are never stored. Two pickers with different queries each get their own answer, and the cached lists stay the same.
5. **Single pages.** `fetchOwnRepos()` and `fetchRemoteBranches(owner:repo:prefix:)` send exactly one request with a 50-item cap and ignore `nextToken`.
6. **Branches.**
   1. `github.branches.listCached` is a first paint only. It is never promoted to the authoritative cache.
   2. A known default branch skips the `github.repos.get` round trip.
   3. A failed authoritative read clears for every consumer on retry. A failed background refresh is silent: the listing stays and no error shows.
   4. A completion from before an invalidation or a reconnect is answered but never cached. The reconnect's own first paint still lands.
   5. `warmRepoCache(owner:repo:)` sends `repo.warmCache` once per repo per connection.
7. **Suggestions.** The local registry is keyed by path, so two clones of one repo give two entries with the same owner and name. Dedupe runs against the displayed rows, so a repo the local prefix filter hides can still come back from server search.

## Code

- `GitHubRepoStore`: `loadIfNeeded(force:)`, `invalidate()`, `hasCheckedAuth`, `isConfigured`, `fetchOwnRepos()`, `searchRepos(query:)`, `fetchDefaultBranch(owner:repo:)`
- `GitHubRepoStore` (branches): `branchState(owner:repo:)`, `cachedBranchListing(owner:repo:)`, `loadBranchListing(owner:repo:defaultBranch:)`, `fetchCachedBranches(owner:repo:)`, `warmRepoCache(owner:repo:)`, `fetchRemoteBranches(owner:repo:prefix:)`
- `GitHubRepoSuggestions`
