# ADR-1003: The GitHub repo picker merges recents, own repos and debounced search

- Status: Accepted
- Recorded: 2026-11-20 (moved from code comments; the decisions are older)
- Applies to: `GitHubRepoPickerView`, `GitHubRepoLabelLayout` (`Intent/Views/Workspaces/GitHubRepoPickerView.swift`)

## Context

`GitHubRepoPickerView` is Create Workspace step 1. It lets the user search and
pick a GitHub repository, or start a new repository.

## Decisions

### 1. Section order and filtering

Applies to: `GitHubRepoPickerView.suggestions`

Recent repos from the daemon's known-repo registry render immediately on top,
with no GitHub round-trip. The first page of the user's GitHub repos blends in
below. Both are prefix-filtered on the client by the typed text. Deduplicated,
debounced global search results follow.

### 2. Without GitHub, show desktop setup guidance; recents are gated too

Applies to: `GitHubRepoPickerView.content`, `GitHubRepoPickerView.notConnectedPlaceholder`

When GitHub is not connected (`github.authStatus.isConfigured == false`), the
screen shows desktop-setup guidance for existing repos. The new-repository
action remains available. Recents are deliberately auth-gated at render time
too: picking a repo needs GitHub for branch listing and workspace creation
either way.

The GitHub connect flow runs on the desktop seat and is not available on iOS.
This follows the same pattern as the "no providers signed in" placeholder
(ADR-1002).

### 3. The store is shared; search state is per picker

Applies to: `GitHubRepoPickerView.store`, `GitHubRepoPickerView.searchResults`, `GitHubRepoPickerView.completedSearchQuery`, `GitHubRepoPickerView.pendingSearchQuery`

`store` is the session-owned cache. On a reopen the cached lists render
immediately (no spinner) while `loadIfNeeded` revalidates silently. Search
state stays in each picker, because every picker on the session shares the
store and one picker's search must not surface in another.

`completedSearchQuery` is the trimmed query that the current `searchResults`
answer. It stays nil until a search completes, so stale results never
surface. `pendingSearchQuery` is the qualifying query currently in its
debounce or remote-search phase.

### 4. Debounced search, latest query wins

Applies to: `GitHubRepoPickerView.scheduleSearch(for:)`

Global search is debounced by about 300 ms
(`Constants.GitHubRepoPicker.searchDebounce`) so rapid keystrokes coalesce
into one request (parity with the desktop front end). Queries shorter than
`GitHubRepoSuggestions.minSearchQueryLength` clear any previous results
instead of searching.

The task publishes the results and the query they answer together, and only if
it is still the latest. An out-of-order older response cannot overwrite a
newer one's results.

### 5. Label layout follows Figma cap-to-baseline spacing

Applies to: `GitHubRepoLabelLayout`

The layout matches Figma's cap-to-baseline text spacing while letting
multiline and accessibility text grow naturally. No glyphs are clipped to a
fixed height.
