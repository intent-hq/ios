# 0052. Daemon wire models: tolerant decoding and vocabularies

**Status:** Accepted (recorded 2026-11-20 from code comments)

## Context

The app talks to daemons of many versions. New daemons add fields and enum values; old daemons leave them out. Model types in `Intent/Models.swift` and `Intent/Models/` decode this wire data. A strict decoder would fail a whole list because of one unknown value.

## Decision

1. **Lenient by default.** A model decodes the fields it needs and makes the rest optional. A row without its required fields is dropped by the caller (for example with `compactMap`), not the whole response.
2. **Raw strings for open vocabularies.** When the daemon can add values later, the model keeps the raw wire string and the presentation layer maps it.
   1. `WorkspacePullRequest` is a subset of PROTOCOL §7.6 `PullRequestInfo`. Only `number` and `status` are required. `status` is the raw serde variant name (`Open`, `Closed`, `Merged`, `Draft`).
   2. `Workspace.prStatus` uses the same values.
3. **Workspace fields (PROTOCOL §5.1).**
   1. `activity` is `idle` or `agent_running`.
   2. `displayStatus` is owned by the daemon (snake_case, for example `pr_open`). It is nil on older daemons.
   3. `attention` is `none`, `unread` or `review_required`. It is nil on older daemons.
   4. `waiting` is independent of the other states (protocol 6.17). The daemon omits it when false, so the custom `init(from:)` decodes a missing key as `false`.
   5. `pullRequests` is the detected-PR pool. `activePullRequest` is the one active PR, nil when absent.
4. **Chief of Staff workspace.** The daemon's virtual Chief of Staff workspace (`Workspace.chiefWorkspaceId`) is never shown in the workspace list.
5. **Providers (PROTOCOL §5.14).**
   1. `ProviderInfo.authenticated` has three states: signed in, signed out, unknown (the probe failed or the provider is not installed).
   2. Only signed-out providers are not selectable. Unknown stays selectable, because probes can fail for a short time.
   3. When the daemon returns providers but none is selectable, the pickers show desktop-setup guidance instead of an empty menu (`noneSelectable`, monorepo#985).
   4. `ModelInfo.isDefault` and `effortLevels` come from `models.list` (protocol 5.30).

## Consequences

- An unknown value shows as a fallback, not as a decode failure.
- Presentation code must handle every optional field and unknown string.

## Code

- `Workspace`: `chiefWorkspaceId`, `activity`, `displayStatus`, `attention`, `waiting`, `prStatus`, `pullRequests`, `activePullRequest`, `init(from:)`
- `WorkspacePullRequest`: `init?(wire:)`
- `ProviderInfo`: `authenticated`, `isSelectable`; `Array<ProviderInfo>`: `noneSelectable`
- `ModelInfo`
