# Agents — ios

Instructions for AI agents working on the SwiftUI iOS companion app. This repo is
tracked as `packages/ios` in [intent-hq/intent](https://github.com/intent-hq/intent);
see the monorepo-root `AGENTS.md` for the cross-package workflow (submodule PR →
monorepo bump, conventional commits).

## Platform guards

visionOS is a destination of the single `Intent` target. `#if os(visionOS)` and
`#if canImport(TailcatKit)` are restricted to an allowlist enforced by
`IntentTests/PlatformGuardAllowlistTests.swift` — the source of truth for which files
may carry each guard; extend the allowlist there when a new guard is deliberate. Every
visionOS branch must leave an iOS branch identical to the prior behaviour.

## Building and testing

Run every xcodebuild build/test through `scripts/xcodebuild.sh` — the single blessed
entry point that CI uses too: `scripts/xcodebuild.sh build-ios | build-visionos |
test-ios`. It fixes the project, scheme, signing flags, and destinations (the
rationale for the destination/SDK rules lives in the script's header comment), and
refuses `-sdk`.

## Where to look

- Thread-hopping ObjC callback APIs (registry + `@Sendable` guard): `IntentTests/ObjCCallbackIsolationTests.swift` — closures passed to these are inferred MainActor-isolated and crash on device when invoked off-main unless explicitly `@Sendable`.

## Filing issues

When you encounter a bug or limitation while working on this codebase, file a GitHub
issue on [intent-hq/ios](https://github.com/intent-hq/ios/issues). iOS findings belong
only in `intent-hq/ios`, not the main `intent-hq/intent` tracker. Do not track issues
in markdown files.

- **Labels**: apply the appropriate `component:*` label (`component:ios` for this repo)
  plus `agent-filed`.
- **Aggressive dedup**: search existing issues first
  (`gh issue list --repo intent-hq/ios --search "<keywords>" --state all`) and
  comment on / link the existing issue instead of filing a duplicate.
- **Cross-reference**: reference the issue number in related commits/PRs (e.g.
  `fix: keep tool block state on sparse ticks (#123)`).
