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
refuses `-sdk`. `test-ios` remains the pre-PR gate; for iteration, re-running one
crashed suite, or mutation checks use the subset forms — `scripts/xcodebuild.sh
test-ios-unit` (skips the `IntentUITests` bundle) and
`ONLY_TESTING='IntentTests/SomeTests ...' scripts/xcodebuild.sh test-without-building`
(one `-only-testing:` per whitespace-separated `Target[/Class[/method]]`; also honoured
by `test-ios` and `test-ios-unit`). `gh workflow run ci.yml --repo intent-hq/ios --ref
<branch> -f only_testing='IntentTests/SomeTests'` runs the same filter in CI as a
non-gating `iOS Filtered Tests` job. iOS builds link the gitignored prebuilt
`TailcatKit/build/TailcatKit.xcframework`: `scripts/xcodebuild.sh` builds it via
`TailcatKit/build_xcframework.sh` when Go is on PATH and otherwise exits naming that
script; `TAILCATKIT_AUTOBUILD=0` disables the auto-build.

The test subcommands hold an exclusive per-simulator lock, so two runs against one
device (two agents in one checkout, or two checkouts picking the same simulator)
serialise instead of killing each other's test processes; a waiter prints the
holder's PID and gives up after `SIM_LOCK_TIMEOUT` seconds (default 1800) with exit
81 — pick another device with `SIM_UDID` rather than sharing one. Exit 80 means the
test process crashed or was terminated rather than a test failing: xcodebuild's
"Failing tests" list then names whichever tests were running, and the wrapper prints
the crash lines and keeps the full log instead. Both behaviours are covered by
`scripts/test_xcodebuild.sh` (bash only, stubbed xcodebuild; run it after editing the
wrapper — CI runs it on the Linux job).

## Where to look

- Thread-hopping ObjC callback APIs (registry + `@Sendable` guard): `IntentTests/ObjCCallbackIsolationTests.swift` — closures passed to these are inferred MainActor-isolated and crash on device when invoked off-main unless explicitly `@Sendable`.
- Transcript scroll / "Go to End" visibility changes: `IntentUITests/ConversationTranscriptScrollUITests.swift` — the XCUITest that runs under `test-ios` against the `--demo-data` long transcript; the fastlane `AppStoreScreenshotTests` stays skipped in the `Intent` scheme.

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
