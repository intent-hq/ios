# ADR-0024: GitHub repo and pull request models parse leniently and match the web client's PR rules

- Status: Accepted
- Recorded: 2026-11-20 (moved from code comments; the decisions are older)
- Applies to: `GitHubRepo`, `GitHubBranchListing`, `GitHubBranchLoadState`
  (`Intent/Models/GitHubRepo.swift`), `GitHubRepoSuggestions`
  (`Intent/Models/GitHubRepoSuggestions.swift`), `MonitoredPr`,
  `MonitoredPrSnapshot` (`Intent/Models/MonitoredPr.swift`), `PullRequestDetail`,
  `PullRequestCheck`, `PullRequestReviewer`, `WorkspaceDiffBuilder.hunks(patch:)`
  (`Intent/Models/PullRequestDetail.swift`), `PullRequestListItem`,
  `PullRequestListRepository` (`Intent/Models/PullRequestListItem.swift`),
  `WorkspacePrPill` (`Intent/Models/WorkspacePrPill.swift`),
  `WorkspacePullRequest` (`Intent/Models.swift`), `WorkspaceCreationDraft`
  (`Intent/Models/WorkspaceCreationDraft.swift`)

## Context

The app shows GitHub repositories in the repo picker, pull requests in a list
and a detail view, PR monitors, and a PR pill on each workspace card. The data
comes from daemon `github.*` reads, PR monitors (PROTOCOL §5.42), and the
workspace's detected PRs. The web client (cloudlands-fe) shows the same data,
and the PR pill must match it exactly.

## Decisions

### 1. Wire DTOs are lenient

Applies to: `GitHubRepo`, `WorkspacePullRequest`, `PullRequestDetail`,
`PullRequestListItem.init(wire:owner:repo:)`, `MonitoredPr`, `MonitoredPrSnapshot`

- `GitHubRepo` is the wire `GithubRepo` DTO (PROTOCOL §5.27), camelCase on the
  wire. Only `owner` and `name` are required. Everything else is optional, and
  parsing tolerates its absence. Its `id` is `owner/name`, because GitHub repos
  are unique per `owner/name`.
- `WorkspacePullRequest` is one detected PR on a workspace, a lenient subset of
  PROTOCOL §7.6 `PullRequestInfo`. `status` keeps the raw wire string ("Open",
  "Closed", "Merged", "Draft"; serde enum variant names) so unknown future
  variants are tolerated. Everything except `number` and `status` is optional.
  `init?(wire:)` is the failable dictionary-path parse (JSONSerialization wire
  shape). Callers drop rows that miss `number` or `status` with `compactMap`.
- `PullRequestDetail` and its siblings parse the detail reads (web Home
  `github.pulls.get`, `.checks`, `.reviews`, `.files`) leniently.
- `PullRequestListItem` is a lenient parse of a `github.pulls.search` result
  (web Home `PullWire` parity). `owner` and `repo` fall back to the batch's
  first repository, because the daemon omits them on single-repository
  searches.
- `MonitoredPr` is the wire `PrMonitor` shape (PROTOCOL §5.42, v6.1). `title`,
  `url`, and `lastSnapshot` are present once the monitor has a successful poll
  baseline. Optional fields are presence-detected (`nil` when absent), never
  defaulted in.

### 2. PR monitor fields

Applies to: `MonitoredPr.State`, `MonitoredPr.repo`, `MonitoredPr.pendingChanges`,
`MonitoredPr.lastError`, `MonitoredPrSnapshot`

- `State` is the monitor lifecycle (PROTOCOL §5.42). `active` is the live
  state. `completed` (PR merged or closed) and `cancelled` are terminal.
  Completed rows are retained so merged PRs stay visible. Cancelled rows are
  excluded from lists.
- `repo` is the combined `"owner/name"` string.
- `pendingChanges` holds human-readable change lines accumulated since the last
  emit, waiting for the debounce window. It is `[]` when nothing is pending.
- `lastError` is the most recent forge-poll error. A successful poll clears it.
- `MonitoredPrSnapshot` is the last-refresh merge-requirements checklist
  summary (§5.42 `lastSnapshot`). Only the display subset is modeled.
  `mergeable`, `mergeBlockedReason`, and `approvals.needed` are
  presence-detected. `approvals.needed` is absent when branch rules are
  unreadable. `mergeability` is the forge tri-state, `.computing` while the
  forge has not reported it.

### 3. Branch listings and their load state

Applies to: `GitHubBranchListing`, `GitHubBranchLoadState`

A branch listing is one repo's branch names plus its default branch, as the
branch picker renders them. It comes both from the authoritative
`github.branches.list` read and from the cached-first
`github.branches.listCached` paint (PROTOCOL §5.27). `defaultBranch` is `nil`
when it cannot be resolved.

`GitHubBranchLoadState` is owned by `GitHubRepoStore` so every consumer (two
sheets on one session, a retry, a reconnect) renders one outcome: the
authoritative listing, the cached-first paint shown only until the listing
lands, and the last cold-load error, which a success clears.

### 4. Repo picker suggestions

Applies to: `GitHubRepoSuggestions`

Suggestions are assembled without side effects. Recent repos (the daemon's
known-repo registry, most recently used first) are pinned on top under a
"Recent" header. The first page of the user's GitHub repos follows. Both are
prefix-filtered by the typed text. Global search results come last, deduped
against everything shown; recents win duplicates. The local registry is keyed
by path, so two clones of one repo give two entries with the same owner and
name. Dedupe runs against the displayed rows, so a repo that the local prefix
filter hides can still come back from server search.

Global search runs only for trimmed queries of at least
`minSearchQueryLength` (2) characters (web parity: the github-repo-search
saga's `MIN_QUERY_LENGTH`). Search results are included only when they answer
the currently typed query (`searchQuery` is the trimmed query the results were
fetched for), so stale in-flight results never surface. This matches the web
RepoSelector's last-query guard.

### 5. Pull request list rules

Applies to: `PullRequestListItem.id`, `linkedWorkspaces(_:)`, `init(githubURL:)`,
`associated(with:monitors:)`, `groupedByProject(_:)`, `PullRequestListRepository.scope(_:)`

- `id` is the lowercased `owner/repo#number`, shared with workspace links.
- `linkedWorkspaces` keys workspaces by every PR they track (detected pool and
  active PR), so a row can open the workspace that owns it. PR URLs win over
  the workspace's own repository, because a workspace may track PRs elsewhere.
- A github.com pull request link is titled by its number until details load.
- `associated(with:monitors:)` returns the workspace's detected pool and active
  PR, including PRs in its git roots, plus agent-monitored PRs in any
  repository, deduplicated by repository and number, newest-updated first.
- `groupedByProject` keeps the incoming newest-first order, so the most
  recently updated project leads. Titles name the owner only when two groups
  share a repository name.
- `PullRequestListRepository.scope` sorts the distinct repositories so the
  scope key is stable.

### 6. Pull request detail rules

Applies to: `PullRequestCheck.summary(_:)`,
`PullRequestReviewer.rows(reviews:requested:)`,
`WorkspaceDiffBuilder.hunks(patch:)`

The collapsed checks row leads with the worst outcome ("2 Failed"), then
pending, then the passed count.

The reviews wire list is oldest first, so `rows` keeps the latest review per
author, then appends requested reviewers who have not reviewed yet. A GitHub
file `patch` contains unified diff hunks without file headers.

### 7. A workspace draft for a pull request opens on the final step

Applies to: `WorkspaceCreationDraft.prefill(pullRequest:)`,
`WorkspaceCreationDraft.pinnedBranch`

`prefill(pullRequest:)` creates a fresh draft for working on a pull request.
Its repository and head branch are selected, and the prompt links the pull
request, so the form opens on the final step. `pinnedBranch` is the pull
request's head branch. It stays selected even when the first branch page does
not list it.

### 8. The workspace PR pill is a port of the web client's helpers

Applies to: `WorkspacePrPill`

`WorkspacePrPill` is a side-effect-free port of the Cloudlands workspace-card
PR pill helpers in `sidebar-changes-utils.ts` (`toPRDisplayStatus`,
`monitorDisplayStatus`, `mergeMonitoredPRs`, `selectPrimaryPr`,
`countOtherMonitors`, `compareMissingLast`), so iOS picks the identical primary
PR and "+N" count. It has no networking or view concerns. A web change to
these helpers needs the same change here.

- `Status` is the web `PRDisplayStatus`: the four pill buckets.
  `Status.init(wire:)` is `toPRDisplayStatus`: it maps the raw wire
  `PullRequestStatus` variant name to a bucket, and unknown future variants
  bucket as `closed`, matching the web client.
- `PillPr` is the pill-relevant subset of a web `PRInfo` row.
  `PillPr.init(_:)` projects a workspace detected-PR row (§7.6), the
  `mapWorkspacePRs` field subset. `crossRepo` is the monitor repo `owner/name`
  when the row came from a monitor on a repo other than the workspace repo,
  `nil` for same-repo rows. `monitorOnly` is true when the row exists only
  because of a monitor.
- `monitorDisplayStatus` (PROTOCOL §6.9): active monitors read the live
  snapshot state. Completed monitors without a snapshot verdict ended merged or
  closed, so they default to the non-celebratory `closed`.
- `mergeMonitoredPRs`: a monitor that duplicates an existing row's
  repo-qualified identity (`crossRepo ?? workspaceRepo` plus number) only
  annotates it, which is a pill no-op, so the row is left untouched. Same-repo
  lookups only match bare (non-`crossRepo`) rows. Unmatched monitors are
  appended as monitor-only rows, with monitor timestamps standing in for the
  PR's own and `crossRepo` set when the repo differs.
- `selectPrimaryPr`: the oldest unmerged (open or draft) PR (`createdAt`
  ascending, number ascending as the tiebreak); otherwise the latest merged PR
  (`updatedAt` descending, number descending); otherwise the first remaining
  (closed) row. Missing timestamps sort last within their bucket. It returns
  `nil` on an empty pool, and callers fall back to the legacy `prStatus` and
  `prNumber`.
- `countOtherMonitors` is the "+N" indicator: monitors whose repo-qualified
  number differs from the primary's. A monitor is excluded only when it matches
  the primary PR by number in the primary PR's repo: `primaryCrossRepo` when
  the primary is a cross-repo monitored row, else the workspace repo. An
  unknown repo matches by number alone.
- `compareMissingLast`: rows with a timestamp sort before rows without one.
  `nil` and empty both count as missing, mirroring TypeScript truthiness.
