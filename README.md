# Intent iOS companion

The **Intent companion app** is a native SwiftUI client for iPhone, iPad, and Apple Vision Pro that connects to the `intentd` daemon over **WSS/TLS with certificate fingerprint pinning**. It provides on-the-go access to workspaces, notes, tasks, and agent conversations over a direct network connection or, on iPhone and iPad, a Tailcat tunnel.

## What it is

- **Native SwiftUI.** Built for iOS 18.0+ / visionOS 2.0+ with async/await, SwiftUI lifecycle, and `@MainActor` isolation. Supports iPhone, iPad, and Apple Vision Pro form factors — visionOS is a destination of the single `Intent` target, not a separate target.
- **Secure pairing.** Pair with `intentd` via **QR code (iPhone/iPad), `intent://pair` deep link, or manual entry**, verify TLS fingerprints (pin-on-first-use or QR code), and authenticate with bearer tokens. Connections without a trusted fingerprint are rejected, including legacy fingerprint-less pairings. Plain `ws://` is available only through an explicit Debug-only loopback test override, never as an app fallback.
- **Local-first mirror.** The app maintains a local cache of workspaces, notes, and agent sessions for offline read access, synced via WebSocket JSON-RPC push notifications.
- **JSON-RPC client.** Talks to `intentd`'s WebSocket transport using the same JSON-RPC 2.0 protocol the desktop client uses.
- **Workspace tools.** Create and transfer workspaces, review staged and unstaged changes and commit diffs, use workspace terminals, and open browser previews served through the daemon.
- **Rich content.** Render Markdown, tables, attachments, and offline Mermaid diagrams in notes and conversations.

## Architecture

An Xcode project with a SwiftUI app target plus unit and UI test targets, structured as:

```text
Intent/
├── App/                       App lifecycle, root/navigation, and
│                              backend session registry
├── Models/                    Domain and wire models
├── Services/                  JSON-RPC transport, live subscriptions,
│                              feature stores, and attachment handling
├── ViewModels/                UI state and feature orchestration
├── Presentation/              View-agnostic presentation logic
│                              (scroll policy, partitioning, classifiers)
├── Views/                     Pairing, workspace, note, and settings UI
│   └── Conversation/          Conversation presentation, transcript,
│                              input, and content rendering
├── DesignSystem/              Colors, theme, layout, and avatar design
├── Utils/                     Shared formatting, links, haptics, and notifications
├── Assets.xcassets            App icons and colors
├── Resources/                 Inter fonts, Lottie animations, and offline Mermaid assets
├── Constants.swift, Models.swift
├── PrivacyInfo.xcprivacy      Privacy manifest
└── PersistenceManager*.swift  Keychain credentials, cached state, drafts, and preferences
IntentTests/                   Unit and integration tests
IntentUITests/                 UI and screenshot tests
TailcatKit/                    Go bridge for iOS Tailcat tunnels
scripts/                       Build/test/lint wrappers and Mermaid vendoring tools
ci_scripts/                    Xcode Cloud dependency preparation
```

The app uses **Network.framework** (`NWConnection` + `NWProtocolWebSocket`) for WebSocket transport, **Textual** for Markdown, **SwiftTerm** for terminal emulation, and **Lottie** for bundled animations. Mermaid diagrams render in a `WKWebView` using bundled JavaScript, without a CDN or runtime Node dependency.

## Pairing

On first launch, the app shows a pairing flow:

1. **QR, deep link, or manual entry**: the user scans a QR code from the desktop app containing the host, port, token, and cert fingerprint, opens an `intent://pair` deep link, or enters them manually. On visionOS the app offers deep link or manual entry only, not QR scanning.
2. **TLS fingerprint verification**: the app computes the SHA-256 fingerprint of the server's self-signed certificate and compares it to the expected fingerprint (from QR or prompt). On mismatch, connection is rejected.
3. **Bearer auth**: the token is sent in the `Authorization: Bearer <token>` header.
4. **Persist credentials**: the token, server info, and paired connections are stored in the **Keychain**; non-secret UI state (active connection id, drafts, last-screen navigation) is kept in `UserDefaults`.

On iOS, pairing information can also include a Tailcat address. The connection
manager races available direct hosts and the tunnel; the winning route still
uses the pinned TLS certificate and bearer authentication.

## visionOS

Apple Vision Pro support is a **destination of the single `Intent` target**: `SUPPORTED_PLATFORMS` includes `xros`/`xrsimulator`, `TARGETED_DEVICE_FAMILY` includes `7`, and `XROS_DEPLOYMENT_TARGET` is `2.0`. Every view, store, and service compiles for visionOS by default; platform differences live behind `#if os(visionOS)` guards. CI keeps the destination green with a dedicated `visionos-build` job (build only, no tests).

Platform limitations on visionOS:

- **No tunnel pairing.** `TailcatKit.xcframework` has no xros slice (gomobile has no visionOS target), so the framework is linked for iOS only and the tunnel path reports an explicit "unavailable" error on visionOS. Connections need a directly reachable daemon, paired via `intent://pair` deep link or manual entry.
- **No QR scanning.** The app's camera-based QR pairing path is hidden on visionOS.

`TailcatKit/build_xcframework.sh` builds the (gitignored) xcframework for the iOS slices. Use Go compatible with `TailcatKit/go.mod` (currently Go 1.27.0 or newer); if needed, select a full toolchain version with `GOTOOLCHAIN`, for example `GOTOOLCHAIN=go1.27.0 ./TailcatKit/build_xcframework.sh`. visionOS builds do not need this framework or Go.

## JSON-RPC Surface

The app uses the daemon's namespaced JSON-RPC API for these capability groups:

- workspace discovery, creation, lifecycle actions, and live state;
- note and comment reading and live state, plus task listing, status changes, and live state;
- agent discovery and lifecycle plus conversation history, sending, queue management, questions, models, and streaming controls;
- attachment upload, placement, and download;
- repository, branch, provider, model, and specialist discovery;
- Git status, diffs, and commit history across workspace repositories;
- workspace transfer and mobile terminal lifecycle, input, output, and resizing; and
- background-hook and pull-request-monitor status and controls.

Live updates combine domain subscriptions for workspaces, notes, tasks, comments, and chats—delivered as `subscription.push` notifications—with filtered `events.subscribe` streams for agent, hook, and pull-request-monitor events.
Browser previews use an auxiliary authenticated WebSocket tunnel rather than
passing daemon credentials to web content.

## Quickstart

### Xcode GUI

A fresh checkout does not contain the gitignored `TailcatKit.xcframework` required
by iOS builds. On macOS with Xcode and the version of Go declared in
`TailcatKit/go.mod`, build it before opening the project:

```bash
TailcatKit/build_xcframework.sh
open Intent.xcodeproj
```

Xcode resolves the Swift package dependencies. Select an iPhone, iPad, or Apple
Vision Pro destination and use **Cmd+R**. The app opens to the pairing screen.
GUI builds run through Xcode itself; command-line builds and tests instead use the
repository wrapper documented below.

Run an `intentd` instance with its TCP WebSocket listener enabled, then scan its QR
code or enter the pairing details manually:

```bash
intentd serve --listen tcp
```

## Dependencies

Direct dependencies managed via Swift Package Manager (integrated in Xcode):

| Package | Project requirement | Purpose |
| --- | --- | --- |
| [Textual](https://github.com/intent-hq/textual) | `0.5.0-intent.4` (exact) | Markdown rendering for notes and messages |
| [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) | `1.18.0` (exact) | Workspace terminal emulation |
| [Lottie](https://github.com/airbnb/lottie-ios) | `4.6.1..<5.0.0` (currently resolved to `4.6.1`) | Bundled animations |

`Intent.xcodeproj/project.pbxproj` declares these requirements;
`Intent.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved` records
the resolved direct and transitive packages. The separate Go bridge pins its
dependencies in `TailcatKit/go.mod` and `TailcatKit/go.sum`.

### Offline Mermaid bundle

`Intent/Resources/Mermaid/` contains the checked-in Mermaid **11.17.2** and ELK
layout **0.2.3** bundle, renderer, licenses, and `vendor.json` provenance. Normal
Xcode builds use those assets directly; Node/npm is only needed to regenerate
them or run the renderer's tests.

To regenerate the bundle from its locked dependencies:

```bash
cd scripts/vendor-mermaid
npm ci
npm run build
```

Review the generated bundle, license notices, and `vendor.json` together. To test
the shipped renderer from the same directory, run `npx playwright install chromium webkit`
then `npm test`. Native coverage lives in `MermaidMarkdownContentTests`,
`MermaidWebViewTests`, and `ConversationMermaidUITests`.
The native Mermaid probes have a five-second JavaScript deadline and require a
successful render before inspecting the page. `MermaidJavaScriptProbeTests`
checks missing and late callbacks, error propagation, and cancellation without
depending on a healthy WebKit process. CI retains unit results and console logs
on cancellation as well as failure so interrupted renderer runs can be inspected.

## Development

### Clean-checkout prerequisites

- For app builds: macOS with Xcode and its command-line tools. Tests require an available iPhone
  simulator by default; use `SIM_UDID` to select an iPad. Every CI Mac selects its
  newest installed GA Xcode 26 (betas and release candidates are skipped); on
  GitHub-hosted `macos-26-xlarge` that is Xcode 26.6 (the local iPhone pool runs 26.3).
- Network access for the first Swift package resolution and pinned Go tool download.
- A Go toolchain compatible with the version in `TailcatKit/go.mod`. iOS commands
  automatically run `TailcatKit/build_xcframework.sh` when the gitignored framework
  is missing and Go is on `PATH`; otherwise they stop with the manual command to run.
  Set `TAILCATKIT_AUTOBUILD=0` to require a prebuilt framework.
- The visionOS platform component for visionOS builds. Install it with
  `xcodebuild -downloadPlatform visionOS` if the wrapper reports that it is missing.

Use `scripts/xcodebuild.sh` for every command-line build and test. It fixes the
project, scheme, signing flags, and destinations, and deliberately rejects extra
arguments such as `-sdk`.

```bash
# Resolve Swift package dependencies
scripts/xcodebuild.sh resolve

# Build the app
scripts/xcodebuild.sh build-ios
scripts/xcodebuild.sh build-visionos

# Run unit tests while iterating, or the complete pre-PR test gate
scripts/xcodebuild.sh test-ios-unit
scripts/xcodebuild.sh test-ios

# Lint (requires SwiftLint 0.65.1; the wrapper enforces the version).
# CI runs this on every PR as the merge-blocking SwiftLint job;
# SWIFTLINT_REPORTER=<name> overrides the config's reporter.
scripts/swiftlint.sh

# Smoke-test the lint wrapper
scripts/test-swiftlint.sh
```

### Strict lint on Linux

The no-argument `scripts/swiftlint.sh` gate uses SwiftLint **0.65.1** with the same
strict rules on both hosts. Linux also needs a loadable SourceKit runtime; a
successful `swiftlint version` does not prove that prerequisite is met.

| Host | Supported route |
| --- | --- |
| Ubuntu 24.04, x86_64 (development and Linux CI) | Native setup below; lint only. |
| macOS with Xcode | Existing SwiftLint 0.65.1 on `PATH` and Xcode toolchain; unchanged invocation. |
| Other Linux distributions / architectures | Automatic setup is unsupported; use one of the hosts above. |

From this repository's root:

```bash
# One-time system prerequisites, if the setup command reports them missing.
sudo apt-get update
sudo apt-get install -y ca-certificates coreutils curl gnupg libc-bin libxml2 tar python3

# Install or reuse SwiftLint and a working SourceKit runtime.
scripts/setup-swiftlint.sh
scripts/setup-swiftlint.sh --check  # read-only prerequisite check
scripts/test-swiftlint-runtime.sh  # real clean and violating fixtures
scripts/swiftlint.sh               # full strict gate; never installs tools

# Offline wrapper, prerequisite, and setup regressions on Linux.
scripts/test-swiftlint.sh
scripts/test-swiftlint-prerequisites.sh
scripts/test-setup-swiftlint.sh
```

On macOS, use `scripts/test-swiftlint.sh` for wrapper smoke tests. The Linux
prerequisite/setup fixtures need Linux host tools; the prerequisite suite currently
depends on `ldd` even though it stubs the reported operating system
([ios#733](https://github.com/intent-hq/ios/issues/733)).

Setup reuses SwiftLint 0.65.1 from `PATH` and an existing usable runtime. If tools
are missing, it installs the checksum-pinned [official SwiftLint release](https://github.com/realm/SwiftLint/releases/tag/0.65.1)
and [Swiftly 1.1.2](https://www.swift.org/install/linux/swiftly/) into
`${XDG_DATA_HOME:-$HOME/.local/share}/intent/swiftlint` (override with the absolute
`INTENT_SWIFTLINT_HOME` path). Swiftly's bootstrap has a pinned SHA256, verified
against its official signature; Swiftly verifies the **Swift 6.3.2** toolchain's
PGP signature before extraction. This runtime matches
[SwiftLint 0.65.1's upstream image](https://github.com/realm/SwiftLint/blob/0.65.1/Dockerfile)
and is exercised by the real fixture check. A fresh runtime download is about
1 GiB and extracts to 3.3 GiB; allow room for both (set `TMPDIR` if needed).

No shell profiles or existing toolchains are changed. The gate finds the managed
installation automatically, while a `swiftlint` already on `PATH` keeps priority
and must match the pin. Remove a mismatched binary from `PATH` before re-running
setup. To select another installed runtime, set `LINUX_SOURCEKIT_LIB_PATH` to the
directory containing `libsourcekitdInProc.so`; an invalid or unloadable override
fails even if a system runtime could otherwise be used. Unset it to return to
automatic selection. The preflight loads an explicit library and runs a small
real lint probe, with crashes and timeouts reported as prerequisite errors.
SwiftLint's executable libraries (including `libxml2`) are checked with `ldd`
before running its version command; missing libraries report the prerequisite
command above. Additional Swift runtime libraries are reported with Swiftly's
package-install command; setup never runs `sudo` for you. Linux support does not
include SwiftUI builds.

To remove the managed tools, delete only the installation directory (by default
`rm -rf ~/.local/share/intent/swiftlint`); if `XDG_DATA_HOME` or
`INTENT_SWIFTLINT_HOME` was set, use that installation's path instead.

### Xcode wrapper commands

The Xcode wrapper supports these subcommands:

| Subcommand | Purpose |
| --- | --- |
| `resolve` | Resolve Swift package dependencies. |
| `build-ios` | Build for the generic iOS Simulator destination. |
| `build-visionos` | Build for the generic visionOS Simulator destination. |
| `build-for-testing` | Build the iOS test bundles for a later test-only run. |
| `build-for-testing-ui` | Build the app and UI tests using the `IntentUI` scheme, without compiling the unit-test bundle. |
| `test-without-building` | Run previously built unit and UI tests. |
| `test-without-building-ui` | Run UI tests built with `build-for-testing-ui`; exclude unit tests from enumeration and execution. Defaults `ONLY_TESTING` to `IntentUITests` and verifies the selected results. |
| `test-without-building-unit` | Run previously built tests without `IntentUITests`. |
| `test-ios` | Build and run the complete unit and UI test gate. |
| `test-ios-unit` | Build and run tests without `IntentUITests`. |
| `pick-simulator` | Print the automatically selected iPhone simulator UDID. |
| `capture-screenshots` | Run the isolated App Store capture test using `CAPTURE_PLATFORM` (`ios` or `visionos`), caller-owned `SIM_UDID`, and `RESULT_BUNDLE`; invoked by `.github/app-store-capture/run.sh`. |

For a focused run, set `ONLY_TESTING` to one or more whitespace-separated
`Target[/Suite[/test]]` selectors. Selectors are test identifiers, not Swift file
names. The wrapper validates each selector before the run, then reports resolved,
executed, skipped, and failed counts per selector:

```bash
ONLY_TESTING='IntentTests/DemoFixturesTests' scripts/xcodebuild.sh test-ios-unit
```

A selector whose tests were all skipped at runtime exits 0 with a notice. Inspect
the per-selector summary and confirm a nonzero executed count before claiming that
a green focused run executed the intended tests.

For repeated focused runs, build once and reuse that build:

```bash
scripts/xcodebuild.sh build-for-testing
ONLY_TESTING='IntentTests/DemoFixturesTests' scripts/xcodebuild.sh test-without-building-unit
```

For UI-only iteration, avoid compiling the unit-test bundle by using the paired
`IntentUI` scheme commands:

```bash
scripts/xcodebuild.sh build-for-testing-ui
ONLY_TESTING='IntentUITests/WorkspaceChangesUITests' scripts/xcodebuild.sh test-without-building-ui
```

Use the regular `build-for-testing` / `test-without-building` pair for mixed unit
and UI selectors. `SIM_UDID` selects a specific simulator; otherwise the wrapper
chooses an iPhone and serializes test runs on that device. Keep `SIM_UDID` and
`DERIVED_DATA_DIR` consistent between a split build and run, and rebuild after
source changes. Use separate derived-data directories for concurrent builds.

For Release verification, set `BUILD_CONFIGURATION=Release` on both build and
test commands (or use `test-ios-unit` to do both). A focused example is
`BUILD_CONFIGURATION=Release ONLY_TESTING='IntentTests/ReleaseConfigurationTests' scripts/xcodebuild.sh test-ios-unit`.
Do not reuse a Debug build as Release evidence: `ReleaseConfigurationTests` is
absent in Debug, and some other suites require Debug-only plaintext fixtures.

The `build-visionos` command always uses the generic visionOS Simulator destination,
never `-sdk`: an `-sdk xros...` invocation can silently fall back to `iphoneos` when
the visionOS platform is absent and produce a bogus successful build.

Tests run **serially** by default — the shared `Intent` and `IntentUI` schemes pin `parallelizable = "NO"`, so no extra flags are needed. Parallel simulator clone runners mass-flake the suite locally (see [intent-hq/intent#759](https://github.com/intent-hq/intent/issues/759)).

### CI and review evidence

`.github/workflows/ci.yml` runs unit tests, the UI smoke selectors in
`scripts/ui-smoke-tests.txt`, and a visionOS build for pull requests and the merge
queue. Smoke coverage uses two balanced iPhone shards and an independent job for
all seven focused iPad sidebar regressions. Each lane owns its build directory,
disposable simulator, results, and evidence. All lanes prefer an idle
self-hosted Mac; GitHub-hosted Macs handle overflow when the local pool is busy.
Matrix fail-fast is
disabled, and the existing `iOS UI Tests` check requires every lane to succeed.
Go tests, wrapper self-tests, and the strict SwiftLint gate run on Linux.
The full UI bundle runs once in one iPhone job, alongside the iPad regressions,
on the default branch at **09:00 and 21:00 UTC** or on manual dispatch:

```bash
gh workflow run ci.yml --repo intent-hq/ios --ref your-branch -f ui_suite=full
gh workflow run ci.yml --repo intent-hq/ios --ref your-branch -f pre_pr_gate=true
gh workflow run ci.yml --repo intent-hq/ios --ref your-branch -f only_testing='IntentTests/DemoFixturesTests'
```

Replace `your-branch` with the branch to test. Filtered dispatches are
**non-gating** and do not replace the normal PR checks.

Both workspace creation entry tests exercise light and dark appearances on every
run, including ordinary PRs.

Each selector in `scripts/ui-smoke-tests.txt` has a `# shard: 1` or `# shard: 2`
annotation. Assign new selectors to a shard and keep suite members together when
practical. `python3 scripts/ui_smoke_tests.py --shard 1` prints that shard's
selection. Invalid annotations, duplicate selectors, or empty shards fail before
native tests start. Run `python3 scripts/test_ui_smoke_tests.py` after changing
selection logic and `python3 scripts/test_ci_simulator.py` after changing the
workflow. Screenshot artifact names use `-iphone-1`, `-iphone-2`, and `-ipad`
suffixes for smoke runs; full runs use `-iphone` and `-ipad`. Simulator and failure
artifacts also include the lane name.

`pre_pr_gate=true` runs the literal `scripts/xcodebuild.sh test-ios` gate,
building once and running unit and UI tests together on an owned iPhone simulator.
It replaces the separate build/unit/UI steps for that dispatch, keeps the visionOS
build, and retains the xcresult, retry results, full gate log and allowlisted fixture
screenshots. It rejects `only_testing` and iPad selection; `ui_suite` is ignored.
For an iPad proof run, add `-f simulator_family=ipad` with 1–20
`Target/Suite[/test]` selectors in `only_testing`; whole-bundle selectors are not
accepted, and each selection must actually execute. This route creates and
cleans up its own simulator and uploads `ios-ipad-execution-evidence`. Like the
iPhone route, it selects an available runtime matching the selected Xcode SDK's
major version and fails before creation if no compatible iPad is available.

The full UI bundle still excludes `AppStoreScreenshotTests` and honors runtime
skips. Quarantined transcript cases in `ConversationTranscriptFullGateUITests`
require `TEST_RUNNER_INTENT_UITEST_FULL_GATE_REPRO=1` on a local wrapper run;
`ui_suite=full` alone does not opt into them.

#### Mermaid UI quarantine

`IntentUITests/ConversationMermaidUITests/testFullscreenButtonEdgeAndInlinePinchAndPan`
is quarantined for intermittent inline and fullscreen render failures tracked in
[ios#735](https://github.com/intent-hq/ios/issues/735). The root cause is unconfirmed.
It is absent from PR/merge-queue smoke selection and skips before app launch in
scheduled full runs, manual full runs, and focused runs unless explicitly enabled.
Neither `ui_suite=full` nor `only_testing` alone enables it.

This intentionally leaves fullscreen button-edge activation, inline pinch zoom,
and two-axis pan without default UI coverage. The assertions, diagram feature,
`MermaidMarkdownContentTests`, and `MermaidWebViewTests` remain intact. For local
diagnosis on a Mac, run from the repository root:

```bash
scripts/xcodebuild.sh build-for-testing-ui
TEST_RUNNER_INTENT_UITEST_MERMAID_REPRO=1 \
  ONLY_TESTING='IntentUITests/ConversationMermaidUITests/testFullscreenButtonEdgeAndInlinePinchAndPan' \
  scripts/xcodebuild.sh test-without-building-ui
```

Only the exact value `1` opts in; the transcript quarantine flag is independent.
Check the wrapper's executed/skipped counts: a skip is not runtime coverage.
Remove the guard and restore the smoke selector together after ios#735 has a
validated fix and repeated unchanged runs pass on the affected CI simulator/Xcode
configurations with the original assertions and timeouts.

### UI evidence artifacts

CI uploads `ios-ui-review-evidence` for 14 days when allowlisted captures exist,
on success or failure and for filtered UI runs. Open its PNGs directly;
`manifest.json` records the tested revision, suite/test, source bundle, and retry
origin. Parallel iPad exports append `-ipad` to evidence artifact names, including
`ios-ui-review-evidence-ipad`, to avoid collisions with the iPhone job. Captures
include workspace creation, iPad sidebars and pairing, menus, changes, and connection-loss
flows; `scripts/export_ui_evidence.py` is the complete allowlist. Missing images
are not proof that a view was captured. `ios-agent-group-evidence` and
`ios-transcript-recovery-evidence` remain separate artifacts. Run
`python3 scripts/test_export_ui_evidence.py` to check the export contract.
On macOS, use `TMPDIR=/private/tmp python3 scripts/test_export_ui_evidence.py`
to avoid the fixture's symlinked temporary-path mismatch
([ios#671](https://github.com/intent-hq/ios/issues/671)).

Final diagnostic attachments use XCTest teardown, since an assertion with
`continueAfterFailure = false` can bypass Swift `defer`. The Linux CI job runs
`python3 scripts/check_ui_attachment_lifecycle.py` and its mutation tests to
reject attachment-producing defer blocks (including named helper calls);
ordinary cleanup remains allowed. The source check is conservative by function
name, not a Swift type checker: it includes parameter defaults but does not
resolve dynamic dispatch, aliases, computed properties, or constructors.

After `scripts/xcodebuild.sh build-for-testing-ui`, run
`python3 scripts/verify_fixture_capture_lifecycle.py --output-root build/capture-contract`
with the same simulator and derived-data settings. The output directory must be
new. The first iPhone smoke shard, or the single full iPhone job, runs this contract
separately from the smoke selection and uploads `ios-fixture-capture-lifecycle`,
including the original failing xcresults,
result JSON, logs, and compact PNG manifests. The isolated abort fixture opts in
only for this verifier; ordinary test runs skip that intentional failure.
The verifier requires exit 65, the original marked assertion recorded as Failed,
a passing companion fixture, and every exact named final PNG under its owning
test in each result bundle. The local verifier defaults to two result bundles.
Ordinary PRs use `--repetitions 1`; capture fixture/exporter/tooling changes,
scheduled runs, manual runs, and the merge queue retain two. If the changed-file
lookup fails, CI keeps two. The selector checks the PR head, base, and file count
before and after fetching files; stale reruns and changing PRs also keep two.
`.github/scripts/select-fixture-capture-repetitions.sh`
defines the relevant paths; its offline regression is
`python3 scripts/test_select_fixture_capture_repetitions.py`. One repetition
still requires repeated passing captures to remain distinct; the second also
checks separation across result bundles. Changing the abort fixture's capture
teardown back to defer must fail
both the source check and this native contract after rebuilding; restore and
rebuild afterward. XCTest teardown does not guarantee evidence after a process crash.

Xcode Cloud uses `ci_scripts/ci_post_clone.sh` to prepare TailcatKit for iOS with
a checksum-pinned Go toolchain; it skips that setup for visionOS. This is build
preparation, not release automation. See [AGENTS.md](AGENTS.md#releases) for
version/build-number checks and the human-controlled upload and release policy.

### Contributor rules

**Conventional commits** are required (`feat`, `fix`, `chore`, `docs`, `refactor`, `test`, `ci`, `perf`); PR titles are validated in CI.
See [AGENTS.md](AGENTS.md) for layout and platform-guard policies, source-input
packaging, focused validation, and issue-reporting requirements. Keep this README
and those instructions aligned when changing build scripts, dependencies, or CI.

## Related Repositories

- [intent-hq/intent](https://github.com/intent-hq/intent) — engineering monorepo that mounts this repo at `packages/ios` and holds cross-cutting docs and tooling.
- [intent-hq/intentd](https://github.com/intent-hq/intentd) — Rust backend daemon this app connects to.

Report bugs and limitations in the iOS app to the
[intent-hq/ios issue tracker](https://github.com/intent-hq/ios/issues), not the
monorepo issue tracker.

## License

This project is licensed under the [Apache License 2.0](LICENSE).

### GitHub Actions runners

Script and Go jobs use GitHub-hosted `ubuntu-24.04`. All macOS jobs prefer
self-hosted Macs: iOS builds and every iPhone/iPad UI lane use the `intent-ios`
pool; visionOS builds and cache warming prefer `intent-ios-build`, then
`intent-ios`. Each pool selects its installed Xcode independently.
The 18 October 2026 validation used Xcode 26.5 on a Depot Mac (the hosted pool
before the move to GitHub-hosted runners) for iPad and 26.3 on the local iPhone Mac.
The pools do not guarantee the same toolchain or simulator runtime. Record the
runner, Xcode, and runtime when comparing timings or investigating failures.
Selectors use `RUNNER_STATUS_TOKEN` to inspect the pools and fall back to
GitHub-hosted `macos-26-xlarge` (Apple Silicon) when every matching local runner is
busy or offline, or runner status cannot be read. Selection uses a snapshot of
runner availability. CI allocates each idle service once across builds and UI
lanes, then sends remaining jobs to hosted Macs. Independent workflows can still
race for the same capacity before GitHub assigns them.
Each local registration must carry `intent-ios-runner-<id>`, using its GitHub
runner ID. The selector verifies that label is unique and includes it in the
job's routing labels, so GitHub schedules the service counted by the allocation.
Missing or duplicate routing labels make that service ineligible for selection.
The selected image needs Xcode 26;
runtime and Metal provisioning run as needed. Go and Swift package caches and
Xcode Cloud distribution remain unchanged. Swift builds do not use sccache.
