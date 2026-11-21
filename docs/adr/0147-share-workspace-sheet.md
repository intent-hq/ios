# ADR-0147: The Share Workspace sheet only creates invite links

- Status: Accepted
- Recorded: 2026-11-20 (moved from code comments; the decisions are older)
- Applies to: `ShareWorkspaceView` (`Intent/Views/Workspaces/ShareWorkspaceView.swift`)

## Decisions

### 1. The sheet creates and sends links; the Mac manages them

Applies to: `ShareWorkspaceView`

The sheet creates an invite link, for anyone or for one GitHub account, and
sends or copies it. People only join by opening a link. Members and open links
are managed in Intent on the Mac, not in this sheet.

### 2. The sheet is as tall as its content

Applies to: `ShareWorkspaceView.body`

The sheet measures its content and uses that height as its only presentation
detent.
