# ADR-1209: Repo owner avatar

- Status: Accepted
- Recorded: 2026-11-20 (moved from code comments; the decisions are older)
- Applies to: `RepoOwnerAvatarView` (`Intent/Views/Components/RepoOwnerAvatarView.swift`)

## Decisions

### 1. The avatar comes from the public GitHub endpoint

Applies to: `RepoOwnerAvatarView`, `RepoOwnerAvatarView.avatarURL(for:)`

The circular repo-owner avatar loads from the public
`https://github.com/{owner}.png` endpoint. It shows a folder icon fallback while
loading, and when the owner is unknown or the image fails to load. It mirrors
the avatar treatment in the desktop `RepoSelector`.
