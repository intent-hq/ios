# ADR-0711: Workspace invite links are capabilities pinned to GitHub accounts

- Status: Accepted
- Recorded: 2026-11-20 (moved from code comments; the decisions are older)
- Applies to: `WorkspaceSharingModel`, `SharingFailure` (`Intent/Services/WorkspaceSharingModel.swift`)

## Context

The Share sheet creates an invite link for one workspace and hands it to the
system share sheet.

## Decisions

### 1. Scope of the Share sheet

Applies to: `WorkspaceSharingModel`

The sheet creates an invite link (`workspace.invite.create`, protocol §5.48)
that anyone can use, or that one GitHub account can use once. People only join
by opening a link. Members and open links are managed on the Mac.

Invite links are capabilities. They are shown and shared on request and never
logged.

### 2. Person links always name GitHub

Applies to: `WorkspaceSharingModel.namesPinProvider`, `WorkspaceSharingModel.namesPinProvider(protocolVersion:)`,
`WorkspaceSharingModel.createLink()`

Hosts on protocol 10.8 or later take `pinProvider` and `pinHost`. Without
`pinProvider`, such a host resolves the login on its own identity's forge, which
may be GitLab. The form names a GitHub account, so the app sends
`pinProvider: "github"` and never lets the host pick its own forge. Older hosts
only resolve pins on GitHub, so omitting the field there is the same.

`InviteLink.pinLogin` is the one account that can use the link, and nil when
anyone can. `normalized` trims the login and drops a leading `@`, so `@octo` and
`octo` are one account.

### 3. Reply shape and expiry text

Applies to: `WorkspaceSharingModel.inviteLink(from:)`, `WorkspaceSharingModel.expiryText`

The reply is `{ invite: { expiresAt, pinLogin? }, url }`. Only an `intent://`
link is shared.

`expiryText` reads "Expires in 7 days." A link minted a moment ago for a week
still reads as 7 days, so partial days round up. Under a day reads as today.

### 4. Failure messages

Applies to: `SharingFailure`

`SharingFailure` maps the documented `error.data.code` values to plain-language
messages.
