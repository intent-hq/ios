# Agents — ios

Instructions for AI agents working on the SwiftUI iOS companion app. This repo is
tracked as `packages/ios` in [intent-hq/intent](https://github.com/intent-hq/intent);
see the monorepo-root `AGENTS.md` for the cross-package workflow (submodule PR →
monorepo bump, conventional commits).

## Project orientation

Start with [README.md](README.md) for setup, architecture, dependencies, and the
complete wrapper command list. The app targets iOS 18.0+ and visionOS 2.0+ with
Swift 6 and default MainActor isolation. `Intent.xcodeproj/project.pbxproj`,
`Package.resolved` under its shared workspace, `TailcatKit/go.mod`, and
`.github/workflows/ci.yml` are the sources of truth for build settings, dependency
versions, and CI behavior. Keep both documents current when changing those contracts.

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
`InfoPlistSyncTests`) reads the copies of `Intent/`, `IntentTests/`, `IntentUITests/`, and
`Info-visionOS.plist` packaged under `IntentTests.xctest/TestSourceInputs/` by the
target's "Copy Test Source Inputs" phase, resolved via `IntentTests/TestSourceInputs.swift`
— never the checkout through `#filePath`, which does not exist on a device (ios#320).

Other source-backed suites use `IntentTests/TestBundleInputs.swift` and the
separate generated `SourceInputs/` manifest. Its build phase uses
`scripts/generate-test-inputs.sh` and `scripts/test-source-inputs.xcfilelist`;
preserve this path as well as `TestSourceInputs/`. Run
`scripts/test-generate-test-inputs.sh` after changing the generator.

## Building and testing

### Builds and focused runs

Run every xcodebuild build/test through `scripts/xcodebuild.sh` — the single blessed
entry point that CI uses too. Use its `build-ios`, `build-visionos`, and `test-ios`
subcommands, not direct xcodebuild invocations. It fixes the project, scheme,
signing flags, and destinations (the rationale for the destination/SDK rules
lives in the script's header comment), and refuses `-sdk`. `test-ios` remains the
pre-PR gate; for iteration, re-running one crashed suite, or mutation checks use
the subset forms — `scripts/xcodebuild.sh
test-ios-unit` (skips the `IntentUITests` bundle) and
`ONLY_TESTING='IntentTests/DemoFixturesTests' scripts/xcodebuild.sh test-without-building-unit`
(one `-only-testing:` per whitespace-separated selector; also honoured by `test-ios`
and `test-ios-unit`). Each selector must resolve to a runnable `Target[/Suite[/test]]`
(a file name is not a selector): the wrapper exits 82 when one matches no runnable
tests or records neither execution nor skips, and 83 when the selection cannot be
verified. An all-skipped selection can exit 0 with a notice; inspect the
per-selector table and confirm actual execution before claiming coverage.

Build once with `build-for-testing` before using `test-without-building[-unit]`.
For UI-only iteration, use `build-for-testing-ui` followed by
`test-without-building-ui`: both select the `IntentUI` scheme, which avoids
compiling `IntentTests`. The latter defaults `ONLY_TESTING` to `IntentUITests` and
verifies the results. Use the regular pair for mixed unit/UI selections. Keep
`SIM_UDID`, `DERIVED_DATA_DIR`, and configuration consistent between a split build
and run; rebuild after source changes and use separate derived-data directories
for concurrent builds.

Set `BUILD_CONFIGURATION=Release` for Release checks. For a focused runtime check,
use `BUILD_CONFIGURATION=Release ONLY_TESTING='IntentTests/ReleaseConfigurationTests' scripts/xcodebuild.sh test-ios-unit`.
For split runs, set the configuration on both commands and rebuild: a Debug build
is not Release evidence. This suite is absent in Debug; some other suites require
Debug-only plaintext fixtures and must not be treated as Release coverage.

### CI selection and evidence

`gh workflow run ci.yml --repo intent-hq/ios --ref <branch> -f only_testing='IntentTests/DemoFixturesTests'`
runs the same filter in CI as a non-gating `iOS Filtered Tests` job, with the
per-selector table in the job summary. In CI, pull requests and the merge queue
run the UI smoke selectors in `scripts/ui-smoke-tests.txt` plus focused iPad sidebar
regressions in independent matrix jobs. Smoke runs use two balanced iPhone shards;
each selector has a `# shard: 1` or `# shard: 2` annotation. Keep the smoke list to
a few fast tests per core flow and update it when renaming a listed test. The full
`IntentUITests` bundle runs on `main` at
09:00 and 21:00 UTC as `iOS UI Tests (full)`,
and on any branch with `gh workflow run ci.yml --repo intent-hq/ios --ref <branch>
-f ui_suite=full`. For an explicitly selected iPad run, add
`-f simulator_family=ipad` with 1–20 `Target/Suite[/test]` selectors; full-bundle
selectors and skipped-only selections are rejected. See the README's CI section
for evidence artifacts and the disposable simulator route.

The first iPhone shard uses the selected Mac pool; the second iPhone shard and
iPad use Depot macOS for independent capacity. Scheduled/manual full runs keep
one full-bundle iPhone job and the iPad regressions. Each job owns its simulator,
build directory, results, and evidence. Keep matrix `fail-fast: false` and the
aggregate `iOS UI Tests` check,
which must fail unless every job succeeds. Filtered and `pre_pr_gate` dispatches
skip the matrix and aggregate. Evidence and failure artifacts include lane names;
screenshots use `-iphone-1`, `-iphone-2`, and `-ipad` suffixes for smoke runs, or
`-iphone` and `-ipad` for full runs. Keep exporter output directories separate too.
Run `python3 scripts/test_ui_smoke_tests.py` after changing shard selection and
`python3 scripts/test_ci_simulator.py` after changing workflow wiring. The selector
must reject invalid/missing annotations, duplicates, and empty shards before
invoking native tests.

Depot adds hosted runner cost, and its installed Xcode/runtime can differ from the
local iPhone pool. Record the actual runner and toolchain in timing evidence.

The native screenshot-retention contract runs once on ordinary PRs and twice
for capture-tooling changes, scheduled/manual runs, and the merge queue. The
first iPhone smoke shard, or single full job, owns this contract; do not duplicate
it in the second shard. The selector
`.github/scripts/select-fixture-capture-repetitions.sh` defaults to two
when changed files cannot be inspected. Run
`python3 scripts/test_select_fixture_capture_repetitions.py` after changing it.
PR metadata must match the event head, base, and file count before and after lookup;
stale reruns and changing PRs keep two repetitions.

Both workspace creation entry tests must exercise light and dark appearances on
every run, including ordinary PRs.

`ui_suite=full` does not opt into quarantined transcript cases:
`ConversationTranscriptFullGateUITests` needs
`TEST_RUNNER_INTENT_UITEST_FULL_GATE_REPRO=1` on a local wrapper run.
`AppStoreScreenshotTests` remains excluded from both `Intent` and `IntentUI`.
For UI evidence, extend the explicit fixture capture allowlist in
`scripts/export_ui_evidence.py`, not a blanket attachment export; run
`python3 scripts/test_export_ui_evidence.py` after changing it (on macOS, prefix
with `TMPDIR=/private/tmp`; see the README). A missing capture is not evidence
that the UI was reviewed.

For the literal full pre-PR gate on CI, dispatch `ci.yml -f pre_pr_gate=true`.
It runs `scripts/xcodebuild.sh test-ios` once instead of the split build/unit/UI
steps, retains the visionOS build and native evidence, and rejects filters or
iPad selection. Default PR checks are unchanged. The full gate honors the same
quarantines and runtime skips; inspect its results before claiming coverage.

### TailcatKit and simulator safety

iOS builds link the gitignored prebuilt
`TailcatKit/build/TailcatKit.xcframework`: `scripts/xcodebuild.sh` builds it via
`TailcatKit/build_xcframework.sh` when Go is on PATH and otherwise exits naming that
script; `TAILCATKIT_AUTOBUILD=0` disables the auto-build. visionOS builds skip it.
Xcode Cloud has separate preparation in `ci_scripts/ci_post_clone.sh`, including
a checksum-pinned Go toolchain. Run `scripts/test-ci-post-clone.sh` after changing
that hook; dependency preparation is not upload or release automation.

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

### SwiftLint

`scripts/swiftlint.sh` is the pre-PR lint gate: it runs SwiftLint 0.65.1 (the wrapper
rejects any other version) with `--strict` from the repository root, and CI runs it on
every PR in the merge-blocking Linux `SwiftLint` job (the release is pinned by
SHA256 in `scripts/setup-swiftlint.sh`). `SWIFTLINT_REPORTER=<name>` overrides the
config's reporter — CI sets `github-actions-logging` for PR annotations; leave it
unset locally.
`scripts/test-swiftlint.sh` (bash, stubbed swiftlint) covers the wrapper; run it after
editing the wrapper — CI runs it on the Linux job too. The Xcode lint phase
(`scripts/swiftlint-xcode.sh`) reads `scripts/swiftlint-xcode-inputs.xcfilelist`; when a
Swift source is added, removed or moved under `Intent/`, `IntentTests/` or
`IntentUITests/`, update that list (sorted with `LC_ALL=C`) — the `SwiftLint` job runs
`scripts/check-swiftlint-inputs.sh`, which fails on any drift from the tracked sources
(`scripts/test-check-swiftlint-inputs.sh` covers the check; CI runs it on the Linux job).

On Ubuntu 24.04 x86_64, use `scripts/setup-swiftlint.sh` then
`scripts/setup-swiftlint.sh --check`; a working SourceKit runtime is required in
addition to the pinned binary. The lint gate never installs tools. Run
`scripts/test-swiftlint-runtime.sh` for real runtime fixtures; run the offline
Linux regressions `scripts/test-swiftlint-prerequisites.sh` and
`scripts/test-setup-swiftlint.sh` on Linux. On macOS, use `scripts/test-swiftlint.sh`;
the prerequisite fixture currently depends on Linux's `ldd`. See the README for
prerequisites and overrides.

## Transport and bundled content

App connections require a trusted certificate fingerprint for WSS/TLS, including
Tailcat routes. Never restore plaintext fallback for legacy saved pairings.
`Intent/Services/WebSocketConnectionSecurity.swift` confines its explicit plaintext
override to Debug loopback tests; Release must continue rejecting missing pins.

Mermaid diagrams use the checked-in assets in `Intent/Resources/Mermaid/`, not a
CDN. Regenerate the vendor bundle through `scripts/vendor-mermaid/` (`npm ci`
then `npm run build` there), rather than hand-editing `mermaid.bundle.js`. Keep
the lockfile, bundle, `vendor.json`, and license notices consistent. The README
documents renderer tests; native coverage is in `MermaidMarkdownContentTests`,
`MermaidWebViewTests`, and `ConversationMermaidUITests`.

## Releases

`Intent.xcodeproj/project.pbxproj` is the version-settings source:
`MARKETING_VERSION` becomes the user-visible `CFBundleShortVersionString`, while
`CURRENT_PROJECT_VERSION` becomes the `CFBundleVersion` build identifier. The app's
iOS and visionOS plists deliberately omit those keys because Xcode generates them
from build settings. Keep both settings consistent across Debug and Release for
`Intent`, `IntentTests`, and `IntentUITests`; preserve the shared iOS/visionOS setup.

Before choosing either number, check the repository settings and App Store Connect/
TestFlight, including uploaded or in-flight builds. Never derive a concrete next pair
from possibly stale checkout values; ask the user if the baseline or intended release
is unclear. For an ordinary fix, default to a patch marketing-version bump unless the
user specifies another release version. Every new release/upload needs that deliberate
marketing-version increase and a fresh build number higher than all known prior uploads.
Apple permits several builds for one version, but project policy allows retaining the
marketing version only for an explicitly requested rebuild of that same unreleased
release; even then, use a fresh, never-reused build number.

Automatic build numbering does not bump the marketing version. If CI or Xcode Cloud
assigns an effective build number, distinguish it from the local
`CURRENT_PROJECT_VERSION` and verify the effective value; do not assume this repository
has release automation. Before upload, inspect `CFBundleShortVersionString` and
`CFBundleVersion` in the actual archived or exported app. Stop on any mismatch and
rebuild—never relabel an old archive. After App Store Connect finishes processing,
confirm the displayed pair and record it in the release handoff. Archive upload,
submission, and release remain human-controlled.

## Where to look

- Thread-hopping ObjC callback APIs (registry + `@Sendable` guard): `IntentTests/ObjCCallbackIsolationTests.swift` — closures passed to these are inferred MainActor-isolated and crash on device when invoked off-main unless explicitly `@Sendable`.
- Transcript scroll / "Go to End" visibility changes: `IntentUITests/ConversationTranscriptScrollUITests.swift` and its companion files — use the `--demo-data` long transcript and read runtime skips; quarantined cases are in `ConversationTranscriptFullGateUITests.swift`.
- Workspace Changes and repository-scoped diffs: `Intent/Services/WorkspaceChangesStore.swift`, `Intent/Services/WorkspaceDiffLoader.swift`, and `IntentUITests/WorkspaceChangesUITests.swift`.
- Terminal sessions and input/output: `Intent/Services/MobileTerminalStore.swift`, `Intent/Services/MobileTerminalConnection.swift`, and `IntentUITests/MobileTerminalUITests.swift`.

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
