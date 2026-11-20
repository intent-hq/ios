# ADR-1005: Pull request list, detail page and link routing

- Status: Accepted
- Recorded: 2026-11-20 (moved from code comments; the decisions are older)
- Applies to: `PullRequestListContent` (`Intent/Views/Workspaces/PullRequestListContent.swift`), `PullRequestSwipeRow` (`Intent/Views/Workspaces/PullRequestSwipeRow.swift`), `PullRequestRowView` (`Intent/Views/Workspaces/PullRequestRowView.swift`), `PullRequestDetailView` (`Intent/Views/Workspaces/PullRequestDetailView.swift`), `PullRequestFileDiffPage` (`Intent/Views/Workspaces/PullRequestFileDiffPage.swift`), `View.pullRequestLinkRouting(inIPadDetail:)`, `EnvironmentValues.openPullRequest` (`Intent/Views/Workspaces/PullRequestLinkRouting.swift`), `IPadPullRequestsSidebar`, `IPadPullRequestDetail` (`Intent/Views/Workspaces/IPadPullRequestsSidebar.swift`)

## Context

Pull requests show as a list on the workspace list page (iPhone) and in the
iPad rail, with a detail page for one pull request and a page per changed
file.

## Decisions

### 1. Reload only on a changed query; debounce text changes

Applies to: `PullRequestListContent`, `PullRequestListContent.sync(_:to:)`

A changed query reloads the list, with search text debounced. An unchanged
query keeps the cached rows when the user switches back from workspaces.

`sync` runs from `.task(id: query)` on the page. Rows are lazy, so the trigger
cannot live on them.

### 2. Grouped rows use distinct ids

Applies to: `PullRequestListContent.body`

Rows in the grouped-by-project list use `grouped:` ids, distinct from the
flat list's ids, so the lazy stack cannot reuse a row that shows the
repository.

### 3. A read-only drop is not an error

Applies to: `PullRequestListContent.body`

While the remote is read-only (`isRemoteReadOnly`), the list shows no failure
row. A drop is not an error, and the list reloads on reconnect.

### 4. Paging stops after a failed page

Applies to: `PullRequestListContent.row(_:linkedWorkspace:showsRepository:)`, `PullRequestListContent.failureRow(_:retry:)`

The last row's `onAppear` loads more only when there is no `loadMoreError`.
After a failed page, only Retry asks again. The failure shows inline under the
rows, which stay visible, with its own Retry.

### 5. Row layout and leading swipe follow the workspace list

Applies to: `PullRequestSwipeRow`, `PullRequestRowView.body`

`PullRequestSwipeRow` uses the workspace list's leading swipe. The state icon
grows into "Open agent" when a workspace tracks the pull request, otherwise
"New workspace", and a completed swipe performs it.

`PullRequestRowView` sits the icon's centre on the title's first line
(`iconBaselineRatio`), like the workspace status icon.

### 6. The detail page uses the workspace page's language

Applies to: `PullRequestDetailView`, `PullRequestDetailView.body`

The detail page has a large title with one quiet subtitle, the shared content
switcher, and plain rows for the linked workspace, checks and reviews above
the description. The Code tab lists the changed files with their diffs.

The header is the workspace page's header: back and the overflow menu. The
large heading carries the title, so the header hides it.

The `pullRequest.detail` accessibility identifier sits on the scroll view
only, so the header controls keep their own identifiers.

### 7. `onClose` replaces dismissal in the iPad main pane

Applies to: `PullRequestDetailView.onClose`, `IPadPullRequestDetail`

Where the page is not presented (the iPad main pane), `onClose` replaces
dismissal. `IPadPullRequestDetail` shows the selected pull request in the iPad
main pane with its own navigation stack for file diffs.

### 8. The review summary shows the one verdict that matters first

Applies to: `PullRequestDetailView.reviewSummary`

The summary reads like "Approved by mona" for one reviewer, or "2 reviewers"
for more.

### 9. A file diff page has no actions

Applies to: `PullRequestFileDiffPage`

One file's diff shows on its own page, under the pull request page's header:
back, the file name with its folder, and no actions.

### 10. Tracked pull request links open the pull request page

Applies to: `View.pullRequestLinkRouting(inIPadDetail:)`, `EnvironmentValues.openPullRequest`

Links to pull requests that a workspace tracks open in the pull request page:
pushed on the stack, or in the iPad main pane. Other links keep their handler.
`openPullRequest` opens a pull request page the way tracked links do. It is
nil outside link routing.

### 11. The iPad rail matches the iPhone page

Applies to: `IPadPullRequestsSidebar`

The iPad rail's Pull requests section has the same list, filters and swipe
actions as the iPhone page. Its title opens the list options.
