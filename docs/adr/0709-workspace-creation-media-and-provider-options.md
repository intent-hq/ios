# ADR-0709: Workspace creation validates media up front and sends the first message safely

- Status: Accepted
- Recorded: 2026-11-20 (moved from code comments; the decisions are older)
- Applies to: `WorkspaceCreationImages` (`Intent/Services/WorkspaceCreationImages.swift`),
  `WorkspaceCreationVideoSubmission` (`Intent/Services/WorkspaceCreationVideoSubmission.swift`),
  `WorkspaceProviderOptions` (`Intent/Services/WorkspaceProviderOptions.swift`)

## Context

The workspace creation form lets the user attach Photos media and pick a
provider. The `workspace.create` request carries the prompt and images; videos
are uploaded after the workspace exists.

## Decisions

### 1. The draft owns its media

Applies to: `WorkspaceCreationImages`

`WorkspaceCreationImages` holds draft-owned Photos media. Videos stay on disk
until the workspace exists.

### 2. Size limits are independent of the daemon frame limit

Applies to: `WorkspaceCreationImages.maximumSourceBytes`, `maximumJPEGBytes`, `maximumRequestBytes`,
`WorkspaceCreationImages.validateRequest(_:)`

The limits bound compressed source reads (30 MiB) and prepared draft memory
(12 MiB JPEG) independently of the daemon's frame limit. `JSONSerialization` may
also escape base64 slashes, which grows the request.

`validateRequest` uses the same serializer and envelope as `ConnectionManager`.
It uses `Int.min` as the RPC id, which conservatively covers every possible
numeric id. `maximumRequestBytes` (39 MiB) leaves 1 MiB below the host's
40 MiB limit.

### 3. Imports are gated and atomic

Applies to: `WorkspaceCreationImages.add(_:)`, `WorkspaceCreationImages.addMedia(_:)`, paste handling

`add` sets the import gate synchronously, before any picker or paste task can
yield to Create. Each batch is atomic: a bad selection never silently drops one
of its images. A cancelled import task may finish after a newer import has
started, so it does not clear the gate.

Paste reads the bytes during the user's paste action, before returning to the
run loop. Lazy pasteboard providers can fail after that action ends or when the
clipboard changes. Decoding and downsampling stay off the main actor.

### 4. The first message waits for every video

Applies to: `WorkspaceCreationVideoSubmission`

`WorkspaceCreationVideoSubmission` holds the first message until every video is
uploaded. The draft retains it across dismissal and failure, including the
server's workspace and agent identity. Before any workspace is created, it
validates the complete prompt and images with
`WorkspaceCreationImages.validateRequest`.

Ordinary sends are not idempotent. The submission reuses the composer's
recovery owner: a lost reply may only be checked, never blindly resent
(protocol §5.5).

### 5. Provider options never fall back to an unfiltered list

Applies to: `WorkspaceProviderOptions`, `WorkspaceProviderOptions.load()`

`WorkspaceProviderOptions` is the host policy for creation forms. A refresh
hides the previous choices until catalog, settings, and authentication have all
been read successfully. `load()` always revalidates on sheet open or retry and
joins concurrent callers. Failed or unsupported reads never fall back to the
unfiltered authentication list.

### 6. Strict decoding of enablement and authentication

Applies to: `WorkspaceProviderOptions` enablement decoding, `AuthenticationEntry.authenticated`

The host returns null for an unset enablement map, but a missing value is an
invalid response. Strict `Bool` decoding rejects numeric flags.

A missing or null `authenticated` decodes as unknown, not as an explicit
signed-out result. This is why the field is an optional `Bool`.
