# ADR-0089: Pull request list and detail stores

- Status: Accepted
- Recorded: 2026-11-20 (moved from code comments; the decisions are older)
- Applies to: `PullRequestListStore` (`Intent/Services/PullRequestListStore.swift`), `PullRequestDetailStore` (`Intent/Services/PullRequestDetailStore.swift`)

## Decisions

### 1. The list matches the desktop Home pull requests list

Applies to: `PullRequestListStore`, `PullRequestListStore.fetch(_:batches:cursors:more:)`

The store lists pull requests across the repositories of the known workspaces.
It is the mobile counterpart of the FE Home pull requests list. It reads
`github.authStatus`, then `github.pulls.search` in batches of `batchSize`
repositories (FE `repositories()` parity). Each batch keeps its own
`nextToken`, so "load more" only asks again for batches that have more
results. With `more`, batches without a cursor are skipped. Rows are sorted
newest-updated first across batches.

### 2. Filter segment order

Applies to: `PullRequestListStore.Filter.allCases`

The segment order puts your own pull requests first.

### 3. A malformed reply is an error, never an empty result

Applies to: `PullRequestListStore.ResponseError`, `PullRequestDetailStore.ResponseError`

A `github.pulls.search` reply without a `pulls` list is an error, never an
empty result. `PullRequestDetailStore.ResponseError.malformed` is a
`github.pulls.get` reply without a readable pull request.

### 4. Loaded rows stay visible through loads and failures

Applies to: `PullRequestListStore.load(_:)`, `PullRequestListStore.loadMoreError`

1. A newer `load` supersedes an older one. Rows from the previous query stay
   visible until the new page lands.
2. On failure, rows of another query must not pass for this query's results,
   so they are cleared. A failed refresh of the same query keeps its rows under
   an error row.
3. `loadMoreError` is a failed "load more". The rows already loaded stay
   visible.

### 5. Detail sections load independently

Applies to: `PullRequestDetailStore`

The store loads one pull request's detail, checks, reviews, and changed files
(FE Home detail parity). Each read is independent: one failing leaves the
others visible with their own retry. Links open with only a number, and the
loaded pull request fills in `item`'s title and state.
