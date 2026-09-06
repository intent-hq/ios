# Agents — ios

Instructions for AI agents working on the SwiftUI iOS companion app. This repo is
tracked as `packages/ios` in [intent-hq/intent](https://github.com/intent-hq/intent);
see the monorepo-root `AGENTS.md` for the cross-package workflow (submodule PR →
monorepo bump, conventional commits).

## Platform guards

visionOS is a destination of the single `Intent` target. `#if os(visionOS)` is allowed
only in the files that already carry it: `App/IntentApp.swift`, `DesignSystem/Layout.swift`,
`DesignSystem/VisionHitTarget.swift`, `Utils/HapticManager.swift`,
`Views/Components/NavigationTitleSubtitleView.swift`,
`Views/Conversation/Composer/MessageInputView.swift`,
`Views/Conversation/Composer/SubmittableTextView.swift`,
`Views/Conversation/Transcript/ConversationColumnView.swift`,
`Views/Onboarding/ManualTokenEntryView.swift`, `Views/Onboarding/PairingView.swift`,
`Views/Onboarding/QRScannerView.swift`, `Views/Workspaces/WorkspaceAttentionCue.swift`,
`Views/Workspaces/WorkspaceDetailView.swift` (plus `IntentTests/PairingOptionTests.swift`);
`#if canImport(TailcatKit)` only in `Services/ConnectionManager.swift`,
`Services/TailcatTunnel.swift`, and `IntentTests/TailcatKitSmokeTests.swift`. Every
visionOS branch must leave an iOS branch identical to the prior behaviour. Verify with
`-destination 'generic/platform=visionOS Simulator'` — never `-sdk xros`, which silently
falls back to iphoneos when the visionOS platform component is not installed.

## Filing issues

When you encounter a bug or limitation while working on this codebase, file a GitHub
issue on [intent-hq/intent](https://github.com/intent-hq/intent/issues) — the single
tracker for all components. Do not track issues in markdown files.

- **Labels**: apply the appropriate `component:*` label (`component:ios` for this repo)
  plus `agent-filed`.
- **Aggressive dedup**: search existing issues first
  (`gh issue list --repo intent-hq/intent --search "<keywords>" --state all`) and
  comment on / link the existing issue instead of filing a duplicate.
- **Cross-reference**: reference the issue number in related commits/PRs (e.g.
  `fix: keep tool block state on sparse ticks (#123)`).
