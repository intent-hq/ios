# ADR-1304: Link and pairing payload parsing

- Status: Accepted
- Recorded: 2026-11-20 (moved from code comments; the decisions are older)
- Applies to: `ExternalLink` (`Intent/Utils/ExternalLink.swift`),
  `IntentFileLink` (`Intent/Utils/IntentFileLink.swift`),
  `InviteLink` (`Intent/Utils/InviteLink.swift`),
  `PairingPayload` (`Intent/Utils/PairingPayload.swift`),
  `WorkspaceAssetLink` (`Intent/Utils/WorkspaceAssetLink.swift`),
  `TcAddressDisplay` (`Intent/Utils/TcAddressDisplay.swift`)
- Related issues: ios#406

## Context

The app opens links that come from the daemon, from agents' Markdown, and from
QR codes. Each parser decides what it accepts so that a hostile or malformed
string cannot drive the app or the system somewhere unexpected.

## Decisions

### 1. External links are web-only

Applies to: `ExternalLink`, `ExternalLink.url(from:)`

`ExternalLink` is the supported contract for backend-supplied external links:
the strings that context-mention chips and PR-monitor chips hand to `openURL`.
Only absolute `http`/`https` URLs with a host are opened. `javascript:`, `file:`,
`tel:`, custom app schemes, scheme-less and malformed strings all resolve to nil,
so a daemon-supplied string can never drive the system into a non-web handler.
There is deliberately no app-link (`intent://`) passthrough: neither call site
has a documented need for one.

### 2. Workspace file links follow the desktop grammar

Applies to: `IntentFileLink`, `IntentFileLink.parse(_:)`, `IntentFileLink.imageExtensions`

The grammar mirrors the desktop intent link grammar:

- `intent://local/file/<workspace-relative-path>`: current workspace
  (`workspaceId` is nil).
- `intent://local/{workspace-id}/file/<path>`: explicit workspace.

The path may contain slashes; everything after the `file` segment is the
workspace-relative path. Segments are percent-decoded on parse, so `path` is
decoded. `parse` returns nil for anything else (note and task links, other
schemes, a missing path) or for a traversal-shaped path.

The raw, still percent-encoded path is split first, so doubled slashes and
encoded slashes (`%2F`) stay visible; then each segment is decoded. The daemon's
`resolve_within` containment is the real boundary. This check is defense in
depth and parity with the desktop parser, which rejects traversal-shaped links
client-side.

Inline images use the extensions png, jpg, jpeg, gif and webp (desktop parity;
no SVG in v1).

### 3. Agent-written paths are accepted as file links

Applies to: `IntentFileLink.parsePath(_:)`

`parsePath` parses a workspace file link that an agent wrote as a path instead of
an `intent://` link: a relative path (`report.html`, `./docs/notes.txt`), an
absolute path, or a `file://` URL with no host (or `localhost`). Relative paths
are workspace-relative. Absolute paths pass through unchanged: the phone cannot
know the workspace folder on the Mac, but the daemon's `file.read` accepts an
absolute path inside the workspace and rejects one outside it, so the viewer
shows its error. Any other scheme, a host-qualified path (`//host/x`), an empty
path (`#summary`) or a traversal-shaped segment returns nil, so those links keep
showing the Can't Open Link message.

### 4. Unsafe segments are rejected after decoding

Applies to: `IntentFileLink.isSafeSegment(_:)`

After decoding, a segment is rejected when it is empty (doubled or trailing
slash), relative (`.` or `..`), or contains a backslash or a slash smuggled in
through percent-encoding. This mirrors the FE's `isSafeWorkspaceRelativePath`.

### 5. Invite links carry a secret that is never shown

Applies to: `InviteLink`, `InviteLink.fingerprint`, `InviteLink.isInviteURL(_:)`,
`InviteLink.parse(_:)`, `InviteLink.url`

An invite link is the share link that `workspace.invite.create` mints:
`intent://invite?v=1&port=<p>&fp=<sha256>&inviteId=<id>&secret=<s>&tc=<addr>`.
The envelope is the pairing link minus the bearer token. Its `secret` only
redeems the invite over the host's unauthenticated `/invite` endpoint, but it
must still never be logged or shown. Current links carry no `host=` and dial
through `tc`. Links minted before the envelope became tunnel-only may still
carry `host=<ip[,ip…]>`.

- `fingerprint` is the SHA-256 of the host's TLS certificate as the link wrote
  it (validated). Compare it with `InvitedSyncKey.sameFingerprint`.
- `isInviteURL` tells whether a URL is an invite link at all, well-formed or
  not. Scheme and host compare case-insensitively (ios#406).
- A repeated query field is ambiguous, so `parse` refuses it rather than pick one.
- `url` is the link in its canonical form, for Copy Link.

### 6. Pairing payloads accept two dialects

Applies to: `PairingPayload`, `PairingPayload.parse(_:)`, `PairingPayload.tcAddress`

A pairing payload is a parsed `intent://pair` QR code. Two dialects exist in the
wild:

- Canonical daemon payload (`pairing.getInfo` / `intentd pair`, protocol §5):
  `intent://pair?v=1&host=<ip[,ip...]>&port=<p>&fp=<sha256>&token=<t>`
- Legacy desktop-app payload (`WebSocketApiSettings`):
  `intent://pair?token=...&host=...&port=...&path=/ws&certFingerprint=...`

`tcAddress` is the Tailcat tunnel address (`tc=`, the "tc..." connection token).
The daemon appends it only when its tunnel is running. It is optional, and empty
values are normalized to nil.

The first non-empty fingerprint wins, canonical `fp=` first, so an empty `fp=`
falls back to a non-empty legacy `certFingerprint=`. Empty values are normalized
to nil so callers take the cert-probe path instead of pinning an empty string.

### 7. Asset links have one identity

Applies to: `WorkspaceAssetLink`

A saved asset belongs to the URL's workspace and has one percent-decoded
identifier. Query and fragment hints are not part of its identity. In
particular, a Markdown-authored backend hint must never select a different
session.

### 8. Tailcat addresses are shortened for display only

Applies to: `TcAddressDisplay.truncated(_:)`

Tailcat (`tc-…`) addresses are shortened for display only: the first 10
characters followed by a single ellipsis when the address is longer than 10
characters, otherwise unchanged. This is never applied to stored values or
pairing payloads; callers keep the full address for accessibility labels.
