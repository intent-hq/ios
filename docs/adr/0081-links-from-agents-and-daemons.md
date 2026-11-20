# 0081. Links from agents and daemons

**Status:** Accepted (recorded 2026-11-20 from code comments)

## Context

Agents write links in Markdown, and daemons put links in chips, QR codes and invites. The phone opens them, so a hostile or careless string must never reach a non-web handler, a path outside the workspace, or another session. Old pairing and invite links are still in the wild.

## Decision

1. **External links.** `ExternalLink.url(from:)` opens only absolute `http` or `https` URLs with a host. Schemes compare case-insensitively. `javascript:`, `file:`, `tel:`, custom schemes, scheme-less and malformed strings resolve to nil. There is no `intent://` passthrough: no call site needs one.
2. **Workspace file links.**
   1. `IntentFileLink.parse(_:)` accepts `intent://local/file/<path>` (current workspace) and `intent://local/<workspace-id>/file/<path>` (explicit workspace), the desktop grammar. Everything after the `file` segment is the workspace-relative path.
   2. The parser splits the raw, still-encoded path, then decodes each segment, so doubled and encoded slashes (`%2F`) stay visible. It rejects empty, `.` and `..` segments and segments with a backslash or a decoded slash (`isSafeSegment(_:)`), like the desktop `isSafeWorkspaceRelativePath`. The daemon's `resolve_within` containment is the real boundary; this is defense in depth and parity.
   3. `IntentFileLink.parsePath(_:)` also accepts a path an agent wrote instead of an `intent://` link: a relative path, an absolute path, or a `file://` URL with no host or `localhost`. Relative paths are workspace-relative. Absolute paths pass through unchanged: the phone cannot know the workspace folder, and the daemon's `file.read` accepts an absolute path inside the workspace and rejects others, so the viewer shows its error. Other schemes, host-qualified paths, empty paths (`#summary`) and traversal segments return nil and show "Can't Open Link".
   4. Inline images are `IntentFileLink.imageExtensions`, as on desktop. No SVG.
3. **Saved assets.** A `WorkspaceAssetLink` belongs to the URL's workspace and has one percent-decoded identifier. Query and fragment hints are not part of its identity. A Markdown-authored backend hint never selects another session.
4. **Pairing payloads.** `PairingPayload.parse(_:)` accepts two dialects:
   1. The canonical daemon payload (`pairing.getInfo`, `intentd pair`, PROTOCOL §5): `intent://pair?v=1&host=<ip[,ip…]>&port=<p>&fp=<sha256>&token=<t>`.
   2. The legacy desktop payload: `intent://pair?token=…&host=…&port=…&path=/ws&certFingerprint=…`.
   3. `v=` and `path=` are ignored. The first non-empty fingerprint wins, `fp=` before `certFingerprint=`. Empty values become nil, so callers probe the certificate instead of pinning an empty string. `tc=` (the Tailcat address) is optional; the daemon adds it only when its tunnel runs.
5. **Invite links.**
   1. `InviteLink` parses `intent://invite?v=1&port=<p>&fp=<sha256>&inviteId=<id>&secret=<s>&tc=<addr>`, minted by `workspace.invite.create`. It is the pairing link without the bearer token.
   2. The `secret` only redeems the invite on the host's unauthenticated `/invite` endpoint, but it is never logged or shown.
   3. Current links have no `host=` and dial through `tc`. Links minted before invites became tunnel-only can still carry `host=<ip[,ip…]>`.
   4. Scheme and host compare case-insensitively (ios#406). A repeated query field is ambiguous, so the parser rejects the link.
6. **Tailcat addresses.** `TcAddressDisplay.truncated(_:)` shortens a `tc-…` address for display only: the first 10 characters and one ellipsis. It never changes stored values or pairing payloads, and accessibility labels keep the full address.

## Consequences

- Dropping the legacy pairing dialect or `host=` invites needs a decision that old QR codes and links no longer work.
- A new link scheme must get its own parser and allowlist; `ExternalLink` stays web-only.
- Every view that hands a daemon-supplied string to `openURL` (context-mention chips, PR-monitor chips) goes through `ExternalLink`, never a bare `URL(string:)` (ios#262). `ExternalLinkTests` scans the call sites from the sources packaged into the test bundle, never the checkout (ios#320, ios#373) (from test comments).

## Code

- `ExternalLink`: `allowedSchemes`, `url(from:)`
- `IntentFileLink`: `parse(_:)`, `parsePath(_:)`, `imageExtensions`, `isSafeSegment(_:)`
- `WorkspaceAssetLink`: `parse(_:)`
- `PairingPayload`: `parse(_:)`, `tcAddress`
- `InviteLink`: `isInviteURL(_:)`, `parse(_:)`, `url`
- `TcAddressDisplay`: `truncated(_:)`
