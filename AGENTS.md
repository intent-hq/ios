# Agents — ios

Instructions for AI agents working on the SwiftUI iOS companion app. This repo is
tracked as `packages/ios` in [intent-hq/intent](https://github.com/intent-hq/intent);
see the monorepo-root `AGENTS.md` for the cross-package workflow (submodule PR →
monorepo bump, conventional commits).

## SwiftUI layout

`GeometryReader` is banned in `Intent/`, `IntentTests/`, and `IntentUITests/`.
Use `onGeometryChange`, `containerRelativeFrame`, `Shape.path(in:)`, or a custom
`Layout` instead. The `geometry_reader_usage` SwiftLint error and
`IntentTests/LayoutPolicyTests.swift` enforce this rule. Do not add disable comments
for the lint rule; the test also rejects them using packaged source inputs.

## Platform guards

visionOS is a destination of the single `Intent` target. `#if os(visionOS)` and
`#if canImport(TailcatKit)` are restricted to an allowlist enforced by
`IntentTests/PlatformGuardAllowlistTests.swift` — the source of truth for which files
may carry each guard; extend the allowlist there when a new guard is deliberate. Every
visionOS branch must leave an iOS branch identical to the prior behaviour. The scan (and
`InfoPlistSyncTests`) reads the copies of `Intent/`, `IntentTests/` and
`Info-visionOS.plist` packaged under `IntentTests.xctest/TestSourceInputs/` by the
target's "Copy Test Source Inputs" phase, resolved via `IntentTests/TestSourceInputs.swift`
— never the checkout through `#filePath`, which does not exist on a device (ios#320).

## Building and testing

Run every xcodebuild build/test through `scripts/xcodebuild.sh` — the single blessed
entry point that CI uses too: `scripts/xcodebuild.sh build-ios | build-visionos |
test-ios`. It fixes the project, scheme, signing flags, and destinations (the
rationale for the destination/SDK rules lives in the script's header comment), and
refuses `-sdk`. `test-ios` remains the pre-PR gate; for iteration, re-running one
crashed suite, or mutation checks use the subset forms — `scripts/xcodebuild.sh
test-ios-unit` (skips the `IntentUITests` bundle) and
`ONLY_TESTING='IntentTests/SomeTests ...' scripts/xcodebuild.sh test-without-building`
(one `-only-testing:` per whitespace-separated selector; also honoured by `test-ios`
and `test-ios-unit`). Each selector must resolve to a runnable `Target[/Suite[/test]]`
(a file name is not a selector): the wrapper exits 82 when one matches nothing or
executes nothing, and 83 when the selection cannot be verified. `gh workflow run
ci.yml --repo intent-hq/ios --ref <branch> -f only_testing='IntentTests/SomeTests'`
runs the same filter in CI as a non-gating `iOS Filtered Tests` job, with the
per-selector table in the job summary. In CI, pull requests and the merge queue
run only the UI smoke selectors in `scripts/ui-smoke-tests.txt` (keep it to a few
fast tests per core flow and update it when renaming a listed test); the full
`IntentUITests` bundle runs on `main` at 09:00 and 21:00 UTC as `iOS UI Tests (full)`,
and on any branch with `gh workflow run ci.yml --repo intent-hq/ios --ref <branch>
-f ui_suite=full`. iOS builds link the gitignored prebuilt
`TailcatKit/build/TailcatKit.xcframework`: `scripts/xcodebuild.sh` builds it via
`TailcatKit/build_xcframework.sh` when Go is on PATH and otherwise exits naming that
script; `TAILCATKIT_AUTOBUILD=0` disables the auto-build.

The test subcommands hold an exclusive per-simulator lock, so two runs against one
device (two agents in one checkout, or two checkouts picking the same simulator)
serialise instead of killing each other's test processes; a waiter prints the
holder's PID and gives up after `SIM_LOCK_TIMEOUT` seconds (default 1800) with exit
81 — pick another device with `SIM_UDID` rather than sharing one. The lock is a
kernel `flock(2)` held by a python3 keeper (no stale state; a killed wrapper's
xcodebuild is terminated before the lock is released). A test-process crash or
runner restart (xcodebuild exit 65 with "Restarting after unexpected exit…" or a lost
test-runner connection) is not a test failure: xcodebuild's "Failing tests" list then
names whichever tests were running, so the wrapper prints the crash lines, keeps the
full log, records the signature in the job summary, and re-runs the interrupted suites
once, alone; a green re-run keeps the run green (exit 0), a failing one exits 65, and a
second crash exits 80 (`TEST_CRASH_RETRY=0` skips the re-run). Both behaviours are covered by
`scripts/test_xcodebuild.sh` (bash + python3, stubbed xcodebuild; run it after editing the
wrapper — CI runs it on the Linux job).

`scripts/swiftlint.sh` is the pre-PR lint gate: it runs SwiftLint 0.65.1 (the wrapper
rejects any other version) with `--strict` from the repository root, and CI runs it on
every PR in the merge-blocking `SwiftLint` job (the release is pinned by sha256 in
`.github/workflows/ci.yml`). `SWIFTLINT_REPORTER=<name>` overrides the config's
reporter — CI sets `github-actions-logging` for PR annotations; leave it unset locally.
`scripts/test-swiftlint.sh` (bash, stubbed swiftlint) covers the wrapper; run it after
editing the wrapper — CI runs it on the Linux job too. The Xcode lint phase
(`scripts/swiftlint-xcode.sh`) reads `scripts/swiftlint-xcode-inputs.xcfilelist`; when a
Swift source is added, removed or moved under `Intent/`, `IntentTests/` or
`IntentUITests/`, update that list (sorted with `LC_ALL=C`) — the `SwiftLint` job runs
`scripts/check-swiftlint-inputs.sh`, which fails on any drift from the tracked sources
(`scripts/test-check-swiftlint-inputs.sh` covers the check; CI runs it on the Linux job).

## Releases

`Intent.xcodeproj/project.pbxproj` is the version-settings source:
`MARKETING_VERSION` becomes the user-visible `CFBundleShortVersionString`, while
`CURRENT_PROJECT_VERSION` becomes the `CFBundleVersion` build identifier. The app's
iOS and visionOS plists deliberately omit those keys because Xcode generates them
from build settings. Keep both settings consistent across Debug and Release for
`Intent`, `IntentTests`, and `IntentUITests`; preserve the shared iOS/visionOS setup.

Fastlane's release lanes read App Store Connect at build time and choose one build
number above every uploaded or in-flight build on either iOS or visionOS, including
older versions and failed builds. Both platforms use the same version/build pair.
The effective build number overrides local `CURRENT_PROJECT_VERSION`; never derive
the next build number from the checkout. Repeated Alpha/Beta builds may share an
unsubmitted marketing version, but every run must use a fresh build number.

`.github/workflows/version-bump.yml` runs `check_version_bump` hourly. When either
platform's current marketing version is submitted, approved or released, it opens
or updates one PR on `automation/marketing-version-bump`, titled
`chore: bump version to X.Y.Z`. The PR increases the patch version for all targets
and configurations; review and merge it before another TestFlight build. The upload
guard blocks closed versions until the bump is merged. Unknown Apple states fail
for human inspection instead of guessing. Submission and App Store release stay
human-controlled; this job never uploads or submits anything.

For a read-only check against real Apple data, dispatch `version-bump.yml` with
`dry_run=true` (also the manual default), or run
`bundle exec fastlane ios check_version_bump dry_run:true` with the ASC API-key
environment variables configured. The workflow runs on Linux without Xcode.
Enable Actions' “Allow GitHub Actions to create and approve pull requests” setting.
For automated PRs to trigger required CI, configure `VERSION_BUMP_TOKEN` as a
fine-grained token with repository Contents and Pull requests read/write access.
Without it, the job uses `GITHUB_TOKEN`; a human must close/reopen the PR to trigger
CI before merging. Never enable automatic merging as part of this workflow.

For a deliberate minor/major release, check the repository and App Store Connect
baseline before choosing a version; ask the user if the intended release is unclear.
Before upload, verify `CFBundleShortVersionString` and `CFBundleVersion` in the actual
archived and exported apps. Stop on any mismatch and rebuild—never relabel an old
archive. After Apple finishes processing, confirm the displayed pair and record it
in the release handoff.

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
