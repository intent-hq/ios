# ADR-0212: Workspace and provider models follow the daemon wire contract and tolerate older daemons

- Status: Accepted
- Recorded: 2026-11-20 (moved from code comments; the decisions are older)
- Applies to: `Workspace`, `ModelInfo`, `ProviderInfo`, `ProviderAuthentication`,
  `Array<ProviderInfo>.noneSelectable` (`Intent/Models.swift`)
- Related issues: monorepo#985

## Context

`Workspace` is the client model of a daemon workspace from `workspace.list` and
`workspace.subscribe`. `ModelInfo` and `ProviderInfo` describe the agent models
and providers the pickers offer. Older daemons omit newer fields, so every
field needs a defined absent value.

## Decisions

### 1. The Chief of Staff workspace is dropped at every ingress

Applies to: `Workspace.chiefWorkspaceId`

`"__chief__"` is the id of the daemon's virtual Chief of Staff workspace. It is
never shown in the workspace list. `workspace.list` filters it server-side, but
a `workspace.subscribe` delta from an older daemon can still carry it, so the
client drops it at every ingress as well.

### 2. Workspace wire fields

Applies to: `Workspace` stored properties

- `activity` is `"idle"` or `"agent_running"`, from the daemon.
- `displayStatus` is a backend-owned wire value in snake_case (for example
  `"pr_open"`). It is `nil` on older daemons.
- `attention` is `"none"`, `"unread"`, or `"review_required"`. It is `nil` on
  older daemons.
- `waiting` is an orthogonal waiting flag (protocol 6.17). It is omitted on the
  wire when false.
- `prStatus` is `"Open"`, `"Closed"`, `"Merged"`, or `"Draft"`.
- `diffSummaryTotalFiles` comes from `diffSummary.totalFiles`.
  `taskStatsTotal`, `taskStatsCompleted`, and `taskStatsInProgress` come from
  `taskStats.total`, `taskStats.completed`, and `taskStats.inProgress`.
- `pullRequests` is the detected-PR pool (§5.1). `activePullRequest` is the
  single active PR (§5.1), `nil` when absent.

### 3. Explicit initializer and decoder

Applies to: `Workspace.init(id:title:...)`, `Workspace.init(from:)`

The memberwise initializer is explicit so `attention`, `waiting`, `createdAt`,
`pullRequests`, and `activePullRequest` can have default values. Existing call
sites and test fixtures that predate those fields stay valid.

The decoder is custom so `waiting` honors the wire contract (PROTOCOL §5.1:
omitted when false). The synthesized decoder would throw `keyNotFound` on the
common not-waiting shape if a `JSONDecoder` path is ever added.

### 4. Model and provider wire fields

Applies to: `ModelInfo`, `ProviderInfo`

- `ModelInfo.id` is the model id (for example `"sonnet4.5"`). `name` is the
  display name (for example `"sonnet4.5 (balanced)"`). `provider` is the
  provider id (for example `"auggie"`).
- `ModelInfo.isDefault` is the provider-reported default model (`models.list`).
  `effortLevels` is the provider-reported reasoning vocabulary (`models.list`,
  protocol 5.30).
- `ProviderInfo` is an agent provider from `host.providerAuthStatus` (PROTOCOL
  §5.14). `authenticated` has three states: `signedIn` (wire `true`),
  `signedOut` (wire `false`), and `unknown` (the probe failed or the provider
  is not installed).

### 5. Only signed-out providers are unselectable

Applies to: `ProviderInfo.isSelectable`, `Array<ProviderInfo>.noneSelectable`

Providers that are `signedOut` are not selectable. `unknown` stays selectable,
because probes can fail transiently.

`noneSelectable` is true when the daemon returned providers but none can be
selected (all signed out). In that state the pickers show desktop-setup
guidance instead of an empty-value menu (monorepo#985).

### 6. Wire models decode leniently and keep open vocabularies as raw strings

Applies to: `Workspace`, `ModelInfo`, `ProviderInfo`, and the other daemon wire
models in `Intent/Models.swift` and `Intent/Models/`

Daemons of many versions talk to the app: newer ones add fields and enum
values, older ones omit them. A model decodes the fields it needs and makes the
rest optional. The caller drops a row that lacks its required fields (for
example with `compactMap`) instead of failing the whole response. When the
daemon can add values later, the model keeps the raw wire string (as
`displayStatus`, `attention`, and `prStatus` do) and the presentation layer
maps it. An unknown value then shows as a fallback, not as a decode failure,
and presentation code must handle every optional field and unknown string.

