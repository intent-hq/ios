# 0049. Workspace screens: creation, pull requests, workspace page and attention

**Status:** Accepted (recorded 2026-11-20 from code comments)

## Context

The workspace list, the workspace page, the pull request pages and the New Workspace sheet read session-owned caches that revalidate in the background and clear on reconnect. On visionOS, workspace rows that need input lift toward the viewer and chime. ADR 0006 owns list status and groups; ADR 0066 owns the creation picker selection; ADR 0082 owns alert sounds.

## Decision

1. **New Workspace sheet.**
   1. Every daemon request (repos, branches, specialists, providers, models, `workspace.create`) goes through the presenting window's session, so a pinned window never reaches another backend.
   2. The repo cache (`GitHubRepoStore`) and the options cache (`CreationOptionsStore`) belong to the session and outlive the sheet. A reopened sheet renders cached lists at once and revalidates silently. Loading state is always derived from the store, never from a local snapshot.
   3. A reconnect hard-clears both stores (`loadGeneration`). The open sheet then drops its settled markers, reloads, and re-warms the selected repo and the selected provider's catalog, so it never waits forever on a cleared cache and Create never enables on a pre-reconnect load.
   4. Lists are observed by value, not by id, so a same-id change (a provider signs out, a specialist becomes hidden, a new default preview) reconciles the selection too.
   5. Create rechecks its conditions at the request boundary, because a refresh can remove the selection after the tap.
   6. The sheet always sends the enabled provider selection, including Auggie. The host default, or a specialist default, can name a disabled provider.
2. **Repo and branch steps.**
   1. Picking a repo warms the daemon's repo cache, so the branch step and `workspace.create` find it fresh (desktop parity).
   2. Branches: a store hit renders at once and revalidates; a failed refresh keeps the cached listing. A miss paints the daemon's local cache (`github.branches.listCached`) while `github.branches.list` loads in parallel; the authoritative result, or its error, wins. The store deduplicates warms per connection.
   3. A new listing keeps the selected branch when it is still listed, else selects the default branch, else the first. The view reconciles explicitly after a cache hit, because an equal listing for another repo does not fire `onChange`.
   4. `GitHubRepoPickerView` shows recent repos from the daemon's registry first, then the first page of the user's GitHub repos, both filtered by prefix on the client, then deduplicated global search results. Global search is debounced about 300 ms (desktop parity); short queries clear results. A result publishes only with the query it answers and only if its task is still the latest. Search state stays per picker; the cache is shared.
   5. Without GitHub (`github.authStatus.isConfigured == false`) the picker hides recents too and shows desktop setup guidance, because branches and creation need GitHub. New Repository stays available. GitHub and provider sign-in run on the desktop, never on iOS.
   6. The prompt editor keeps Return as a newline. Paste checks only image metadata (`hasImages`) and never reads clipboard content on render or focus.
3. **Pull requests.**
   1. A changed query reloads (search text debounced). An unchanged query keeps the cached rows when the user switches back from workspaces.
   2. A connection drop is not an error; the list reloads on reconnect. After a failed page, only Retry loads more.
   3. Links to a pull request that a workspace tracks open the pull request page, pushed or in the iPad main pane. Other links keep their handler.
   4. The leading swipe grows the state icon into "Open agent" when a workspace tracks the pull request, else "New workspace". A completed swipe performs it.
4. **Workspace page.**
   1. Each window keeps the stores of its last few viewed workspaces (`WorkspaceDetailStoresCache`), so a switch back or a drop shows them from memory. The cache is not observable, so a lookup during view evaluation does not invalidate the view. Teardown removes only this workspace and connection pair.
   2. A retained workspace keeps its expanded agent groups; only fresh stores reset.
   3. Archive and delete ask first: an alert on iPhone and iPad, a focused sheet with one primary action on visionOS. They go through `WorkspaceStore`. The page leaves as soon as the store removes the row; if the server does not confirm, the page stays and shows the server's message.
   4. When the workspace list loaded and no longer has this workspace, it was archived or deleted elsewhere, and the page leaves.
   5. Owners, and host members who manage every workspace, can share while connected. The host still refuses anyone it does not allow. People join only by opening an invite link; members and open links are managed on the Mac.
   6. During a drop, a title draft stays in the field and nothing is sent.
   7. A terminal error already shown inline is not shown again as an alert.
   8. In the Duo shell, the rail carries the page actions, as for conversations. A system vertical toolbar would add an opaque bar over the pane.
   9. In the iPad sidebar copy of the page, an agent opened from elsewhere switches to the Agents tab. The sidebar adopts the overview's open sections and opens and loads the sections above the agent, so the open agent's row stays in view.
5. **Status image** (PROTOCOL §5.1 `statusImageAssetId`, desktop `WorkspaceProgressCard.svelte`). A blank id is treated as unset, as the daemon does. The image loads through `note.readAsset`; a new asset id or a retry re-runs the fetch, and a superseded fetch never overwrites a newer image. An unset image leaves no gap; a loading or failed image keeps its square.
6. **File preview.** A media preview failure names its cause: too large (retry cannot help), unsupported type (WebM), damaged bytes (retry cannot help), unexpected response, or request failure. Every extension routed to the media preview is one the device decodes, so a decode failure means damaged bytes.
7. **Workspace browser.** A main-frame load failure replaces the page until the next load or Reload. A cross-origin subframe failure shows a message, and a main frame still loading keeps its spinner until `didFinish`.
8. **visionOS attention.**
   1. A workspace needs input when its display status is an attention status (blocker, discussion, question, plan approval) or its server-owned unread flag is set (`workspaceNeedsInput(_:)`). The unread part clears with `workspace.markSeen` on open.
   2. Such a row lifts slightly toward the viewer and scales once on change, with no looping animation (HIG), and its status chip brightens.
   3. While the Intent menu is open, raised rows are hidden: no lift, no input, not in accessibility. This is presentation only; the unread flag is never changed, so the rows return when the menu closes. The hide is not animated. The menu's cards sit 24 pt in front of the window, ahead of a raised row, and use opaque cards under Reduce Transparency.
   4. `WorkspaceAttentionCueTracker` primes silently on its first non-empty observation, so items pending at launch never chime. Then only absent → present transitions count, and a cleared item can chime again.
   5. `WorkspaceAttentionCueCenter` is shared per session. Identical observations from several list surfaces are idempotent. One cue plays per batch with a new item. On visionOS the session's window plays it from its own scene (`WindowCueEvent`, ADR 0044); elsewhere a short system sound plays.
   6. The attention cue and the `agent:idle` chime often come from the same agent event. Whichever plays first for a workspace silences the other kind for that workspace for 2.5 s (`dedupInterval`). Same-kind repeats and visual cues are not affected (ADR 0082).
9. **Intent menu.** The action launcher floats over navigation content without resetting its scroll position. While the menu is open, the window's floating chat composer hides but keeps its draft and imports (`coversConversationComposers(while:)`). An enabled launcher sets accessibility visibility explicitly, so the drawer can hit-test it while closed; a disabled launcher must keep the hidden states of retained iPad panes (`accessibilityHidden(_:isEnabled:)`).
10. **Toolbars and system traits.** Native toolbar hosts must not depend on inherited observable objects (#745); pass values such as `canCreateWorkspace`. The vertical-bar edge trait is system-owned, and the app never writes it.
11. **Home tiles.** With accessibility text sizes, the home carousel shows one card per viewport, so titles wrap at word boundaries, and the carousel scrolls vertically when cards are taller than a short landscape window.
12. **Group heading identifiers.** The iPhone list and the iPad sidebar use the same group heading accessibility identifiers (`WorkspaceListGroupHeading.accessibilityIdentifier(for:in:)`), so UI tests address both the same way.
13. **Sidebar rows.** The explicit row background replaces the sidebar's accent selection with neutral grey and suppresses the keyboard focus halo. On visionOS it also replaces the system gaze highlight, so the hover effect is applied again to the row with the same shape as the selection (ios#339).

## Code

- `CreateWorkspaceView`: `fetchBranches()`, `reconcileBranchSelection(with:)`, `fetchCreationOptions()`, `loadModels(for:)`; `SpecialistPickerView`; `CreateWorkspaceSpecialistStepView`
- `GitHubRepoPickerView`: `scheduleSearch(for:)`, `completedSearchQuery`; `WorkspacePromptUITextView`
- `PullRequestListContent`: `sync(_:to:)`; `PullRequestSwipeRow`, `pullRequestLinkRouting(inIPadDetail:)`
- `WorkspaceDetailStoresCache`, `WorkspaceDetailPresentation`: `perform(_:workspaceId:store:onLeave:)`, `resetForWorkspaceChange()`; `WorkspaceActionConfirmations`, `ShareWorkspaceView`, `WorkspaceTitleEditor`
- `WorkspaceStatusImageLayout`, `WorkspaceStatusImageView`; `WorkspaceFilePreview.Failure`; `WorkspaceBrowserPage`: `reportCrossOriginSubframe()`
- `workspaceNeedsInput(_:)`, `WorkspaceAttentionCueTracker`, `WorkspaceAttentionCueCenter`: `noteAlertChimeWillPlay(workspaceId:)`, `dedupInterval`; `WorkspaceAttentionCuePresentation`, `WorkspaceActionMenuDepth`, `visionAttentionCue`, `visionWorkspaceAttentionSound(_:)`
- `WorkspaceListContentKind`, `WorkspaceActionLauncher`
