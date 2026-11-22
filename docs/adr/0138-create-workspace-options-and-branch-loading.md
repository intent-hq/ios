# ADR-0138: Create Workspace reads options and branches from session stores and gates Create on settled loads

- Status: Accepted
- Recorded: 2026-11-20 (moved from code comments; the decisions are older)
- Applies to: `CreateWorkspaceView` (`Intent/Views/Workspaces/CreateWorkspaceView.swift`), `CreateWorkspaceView.showsOptionsLoading`, `CreateWorkspaceView.showsModelCatalogLoading`, `CreateWorkspaceView.buildCreateWorkspaceParams`, `CreateWorkspaceView.createRequestTimeout` (`Intent/Views/Workspaces/CreateWorkspaceSpecialistStepView.swift`)

## Context

The Create Workspace sheet picks a repository, a branch, a specialist, a
provider and a model, then sends `workspace.create`. The repository, branch
and option lists come from caches that the session owns. The caches can be
warm, cold, revalidating, or cleared by a reconnect while the sheet is open.

## Decisions

### 1. Every daemon request goes through the presenting window's session

Applies to: `CreateWorkspaceView.session`

The sheet holds the presenting window's `BackendSession`. All daemon requests
(repo and branch listing, specialist, provider and model options, and
`workspace.create`) go through its connection, so pinned windows never hit the
default backend.

### 2. The repo cache and the options cache are session-owned

Applies to: `CreateWorkspaceView.githubStore`, `CreateWorkspaceView.optionsStore`

`GitHubRepoStore` (`session.githubRepoStore`) and `CreationOptionsStore`
(`session.creationOptionsStore`) outlive the sheet. A reopen renders the
cached lists instantly while the stores revalidate in the background. Both
caches follow this contract.

### 3. Specialists: modal-pickable set, orchestrator first, then by name

Applies to: `CreateWorkspaceView.specialists`, `CreateWorkspaceView.reconcileSpecialistSelection()`

The picker offers the modal-pickable set with the orchestrator pinned first,
then sorted by name (`CreationSelectionPolicy.workspacePickerSpecialists`).
Reconciling defaults the selection to the orchestrator, else the first
specialist, and re-defaults or clears it when the selected specialist left the
pickable set.

### 4. An empty model catalog hides the model row

Applies to: `CreateWorkspaceView.models`

`models` is the selected provider's cached catalog. It is empty until loaded,
and an empty catalog hides the model row. The daemon default model then
applies.

### 5. Loading states derive from the store, never from a local snapshot

Applies to: `CreateWorkspaceView.isLoadingOptions`, `CreateWorkspaceView.branchState`

`isLoadingOptions` reads the store. A cache that warms between construction
and the step's load (another sheet, a reconnect reload) drops the loading
state on its own. A reconnect clear drives it back on while the store reloads
cold.

`branchState` is the branch step's state for the selected repo: the
authoritative listing, the cached-first paint and the cold-load error. The
store owns it. Another sheet's load, a retry and the reconnect clear all reach
this sheet through the store, and nothing in the sheet can outlive them.
`branchListing` shows the authoritative listing first (synchronous on a
revisit), else the paint.

### 6. `settledLoads` records which of the sheet's own loads returned

Applies to: `CreateWorkspaceView.settledLoads` (`SpecialistPickerView.SettledLoads`), `CreateWorkspaceView.showsOptionsLoading`

`settledLoads` records the options load and the model load per provider. A
cold load that failed then shows the empty state or falls back to the daemon
default instead of loading forever, while Create stays disabled until the
selected provider's catalog is resolved. A marker is published only for a load
that returned in the store generation it started in. A reconnect clear resets
every marker.

`showsOptionsLoading`: a failed cold load settles; an uncached load still in
flight gates creation.

### 7. Create waits for the selected provider's model catalog

Applies to: `CreateWorkspaceView.isLoadingSelectedModelCatalog`, `CreateWorkspaceView.showsModelCatalogLoading`

The gate is true while the selected provider's catalog is uncached and the
sheet's load for that provider has not settled. Create stays disabled (as
before the cache existed), so a workspace is never created before the
provider's model choices are known. The gate is per provider: switching to an
uncached provider re-arms it. A warm catalog is instant and never gates.

In `showsModelCatalogLoading`, a missing provider needs no load, and a failed
catalog falls back to the daemon default.

### 8. Branch listing: cached-first paint, then the authoritative list

Applies to: `CreateWorkspaceView.fetchBranches()`, `CreateWorkspaceView.resetRepositoryState()`

On a store hit, the sheet renders synchronously and revalidates silently. A
failed refresh keeps the cached listing. On a miss, the store paints the
daemon's local cache (`github.branches.listCached`) as soon as it answers,
while the authoritative `github.branches.list` loads in parallel. The
authoritative result, or its error, wins once it settles.

Every load (step open, retry, reconnect) re-warms the daemon's repo cache. The
store deduplicates warm requests per connection. Picking a repository warms
the cache at once, so the branch step's cached-first paint and the later
`workspace.create` find it fresh (parity with the desktop front end).

Outcomes live in the store, so a repo change simply stops reading the old
repo's state.

`fetchBranches` reconciles the selection with a cached listing explicitly, not
only through `onChange(of: branchListing)`. An equal listing for another repo
(two repos with just `main`) never fires the observer.

### 9. Every listing change reconciles the branch selection

Applies to: `CreateWorkspaceView.body` (`onChange(of: branchListing)`)

The cached-first paint, the authoritative listing that replaces it and a
background revalidation all land in this observer. It keeps the selection if
the new listing still has it, else falls back to the default branch, then the
first branch.

### 10. A reconnect clear reloads the open step

Applies to: `CreateWorkspaceView.reloadBranchesAfterInvalidation()`, `CreateWorkspaceView.reloadOptionsAfterInvalidation()`

A reconnect hard-clears `GitHubRepoStore`: every listing, paint, error,
in-flight branch load and the warmed set, whatever the repo held (nothing yet,
a paint, an error, a listing). The sheet observes `loadGeneration`, and while
the branch step is open it reloads and re-warms the selected repo, so the step
never sits loading forever on a cleared cache.

A reconnect also hard-clears `CreationOptionsStore`. Every settled marker
belonged to the dropped cache, so the sheet drops them. While the create step
is open it reloads (joining the store's own cold reload) and re-warms the
selected provider's catalog, so Create gates on the fresh load and does not
stay enabled on a pre-reconnect one.

### 11. Selections reconcile against swapped lists, observed by value

Applies to: `CreateWorkspaceView.navigationContent`

A background revalidation or a reconnect reload swaps the cached lists under
an open sheet, and the selections must stay valid. The specialist list is
observed by value, not by id, so a same-id metadata change (a provider signing
out, a specialist turning hidden, a fresh default preview) reconciles too.

Loading, loaded-empty and failed provider states all project to an empty
provider list. The sheet observes `providerOptions.state` instead, so a
completed validation still reconciles.

### 12. Cold and cached option loads

Applies to: `CreateWorkspaceView.fetchCreationOptions()`, `CreateWorkspaceView.loadModels(for:)`

Cold (nothing cached): the sheet awaits the specialist and provider load while
`isLoadingOptions` shows, then the selected provider's model catalog with
Create disabled. Each load settles on its own, on success or failure. Cached:
the pickers already render the cached lists, the store revalidates in the
background, and neither loading state shows.

A load superseded by a reconnect clear publishes nothing. The
`loadGeneration` change starts a fresh load that settles and reconciles.
`loadModels` loads the catalog (instant when cached) and settles its Create
gate only when the load returned in the generation it started in. A
completion from before a reconnect clear settles nothing.

### 13. Provider default and model reset

Applies to: `CreateWorkspaceView.reconcileProviderSelection()`

The provider selection defaults to a selectable provider, with auggie first,
and the selected provider's model catalog loads: instant when cached, awaited
when cold. An explicit model never survives a provider switch (the daemon
default applies), even when the new provider's catalog shares a bare model id
with the old one.

### 14. Recheck the gates at the request boundary

Applies to: `CreateWorkspaceView.performCreateWorkspace(source:)`

The task rechecks `canCreateWorkspace`, the provider gate and image import
before it sends. A refresh may have removed the selection after the tap but
before the task ran.

### 15. Always send the enabled provider selection

Applies to: `CreateWorkspaceView.buildCreateWorkspaceParams(source:idempotencyKey:initialAgent:)`

The `initialAgent.provider` parameter is always sent for the enabled
selection, including Auggie. The host's default (or the specialist's default)
may name a disabled provider.

### 16. The request leaves ids, clone paths and defaults to the daemon

Applies to: `CreateWorkspaceView.buildCreateWorkspaceParams(source:idempotencyKey:initialAgent:)`

- `initialAgent` never carries an `agentId`; the server assigns agent ids.
- With `githubUrl`, the request omits `repositoryPath` and `clonePath`, which
  selects the daemon's cache-hydrated clone (PROTOCOL §5.1). `baseRef` is the
  plain branch name from `github.branches.list`, with no remote prefix.
- An empty message omits `prompt`, like the desktop, so a specialist alone can
  create the workspace.
- A model is sent only when the user picked one, even when it equals the
  specialist's resolved default preview.

### 17. `workspace.create` gets a 120-second timeout

Applies to: `CreateWorkspaceView.createRequestTimeout`

`createRequestTimeout` is 120 s, like cloudlands-fe `CREATE_TIMEOUT_MS`
(#1954). The daemon's NPX budget plus first-turn overhead exceeds the default
10 s request timeout.
