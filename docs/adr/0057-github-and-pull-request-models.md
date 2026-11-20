# 0057. GitHub repository and pull request models

**Status:** Accepted (recorded 2026-11-20 from code comments)

## Context

The app shows GitHub repositories (repo and branch pickers for new workspaces), pull requests (list, detail, workspace pills) and PR monitors. These come from `github.*` reads, workspace PR fields and `PrMonitor` rows. The desktop Home and workspace card show the same data, so the selection and grouping rules must match.

## Decision

1. **Repositories (PROTOCOL §5.27).**
   1. `GitHubRepo` is the camelCase `GithubRepo` DTO. Only `owner` and `name` are required.
   2. `GitHubBranchListing` comes from the authoritative `github.branches.list` and from the cached-first `github.branches.listCached` paint. `defaultBranch` is nil when unresolvable.
   3. `GitHubRepoStore` owns `GitHubBranchLoadState` for each repo, so every consumer (two sheets, a retry, a reconnect) shows one outcome. The authoritative listing wins; the paint shows only until it lands; the last cold-load error is cleared by a success.
2. **Repo picker suggestions** (`GitHubRepoSuggestions`).
   1. Recent repos (the daemon's known-repo registry, most recent first) are on top under "Recent". The first page of the user's own repos follows, then global search results.
   2. Recents and own repos are filtered by a case-insensitive prefix match on `owner/name` or the bare name. Own repos are deduplicated against recents, and search results against both.
   3. Global search runs only for trimmed queries of at least two characters (FE `MIN_QUERY_LENGTH`).
   4. Search results show only when they answer the currently typed query, so stale results never surface (FE RepoSelector last-query guard).
3. **Workspace creation draft.** A draft for a pull request selects its repository and head branch and links the PR in the prompt, so the form opens on the final step. The head branch stays selected (`pinnedBranch`) even when the first branch page does not list it.
4. **Pull request list** (`PullRequestListItem`, FE Home `PullWire`).
   1. Rows are a lenient parse of `github.pulls.search`. `owner` and `repo` fall back to the batch's first repository, because the daemon omits them on single-repository searches.
   2. The id is the lowercased `owner/repo#number`. Workspace links use the same key.
   3. A workspace is linked to every PR it tracks (detected pool and active PR). PR URLs win over the workspace's own repository, because a workspace can track PRs elsewhere.
   4. A workspace's PRs are its detected pool and active PR (including git roots) plus agent-monitored PRs in any repository, deduplicated by repository and number, newest-updated first.
   5. Groups keep the incoming newest-first order. A group title names the owner only when two groups share a repository name.
5. **Pull request detail** (`PullRequestDetail`, FE Home `github.pulls.get`, `.checks`, `.reviews`, `.files`).
   1. The collapsed checks row leads with the worst outcome ("2 Failed"), then pending, then the passed count.
   2. Reviewers: one row per author with their latest review (the wire list is oldest first), then requested reviewers who have not reviewed.
6. **PR monitors (PROTOCOL §5.42, v6.1).**
   1. `title`, `url` and `lastSnapshot` exist once the monitor has a successful poll baseline. Optional fields are presence-detected, never defaulted.
   2. `active` is live. `completed` (merged or closed) rows stay visible. `cancelled` rows are excluded from lists.
   3. Only the display subset of `lastSnapshot` is modeled. `mergeable`, `mergeBlockedReason` and `approvals.needed` are presence-detected; `needed` is absent when branch rules are unreadable.
7. **Workspace PR pill** (`WorkspacePrPill`). It ports the desktop `sidebar-changes-utils.ts`, so iOS picks the same primary PR and "+N" count. See also ADR 0006.
   1. `toPRDisplayStatus`: the raw `PullRequestStatus` variant maps to a pill bucket. Unknown variants become `closed`.
   2. `monitorDisplayStatus` (PROTOCOL §6.9): an active monitor reads its snapshot state. A completed monitor without a verdict shows `closed`, not a celebration.
   3. `mergeMonitoredPRs`: a monitor that duplicates a row's repo-qualified identity (`crossRepo ?? workspaceRepo` + number) changes nothing. Same-repo lookups match only rows without `crossRepo`. Other monitors append as monitor-only rows, with monitor timestamps and `crossRepo` set when the repo differs.
   4. `selectPrimaryPr`: the oldest unmerged (open or draft) PR by `createdAt`, number as tiebreak; else the latest merged by `updatedAt` desc; else the first closed row. Missing timestamps sort last in their bucket (`compareMissingLast`, TS truthiness). An empty pool gives nil, and callers fall back to `prStatus`/`prNumber`.
   5. `countOtherMonitors`: monitors whose repo-qualified number differs from the primary's. The primary's repo is its `crossRepo`, else the workspace repo; an unknown repo matches by number alone.

## Consequences

- A desktop change to these helpers needs the same change here.
- Unknown PR states never hide a PR; they show as closed.

## Code

- `GitHubRepo`, `GitHubBranchListing`, `GitHubBranchLoadState`: `displayed`
- `GitHubRepoSuggestions`: `minSearchQueryLength`, `prefixFiltered(_:query:)`, `merged(…)`
- `WorkspaceCreationDraft`: `pinnedBranch`, `prefill(pullRequest:)`
- `PullRequestListItem`: `init?(wire:owner:repo:)`, `key(owner:repo:number:)`, `linkedWorkspaces(_:)`, `associated(with:monitors:)`, `groupedByProject(_:)`
- `PullRequestCheck.summary(_:)`, `PullRequestReviewer.rows(reviews:requested:)`
- `MonitoredPr`, `MonitoredPrSnapshot`
- `WorkspacePrPill`: `monitorDisplayStatus(_:)`, `mergeMonitoredPRs(…)`, `selectPrimaryPr(_:)`, `countOtherMonitors(…)`
