# Intent iOS companion

The **Intent companion app** is a native SwiftUI client for iPhone, iPad, and Apple Vision Pro that connects to the `intentd` daemon over **WSS/TLS with certificate fingerprint pinning**. It provides on-the-go access to workspaces, notes, tasks, and agent conversations over a direct network connection or, on iPhone and iPad, a Tailcat tunnel.

## What it is

- **Native SwiftUI.** Built for iOS 18.0+ / visionOS 2.0+ with async/await, SwiftUI lifecycle, and `@MainActor` isolation. Supports iPhone, iPad, and Apple Vision Pro form factors — visionOS is a destination of the single `Intent` target, not a separate target.
- **Secure pairing.** Pair with `intentd` via **QR code (iPhone/iPad), `intent://pair` deep link, or manual entry**, verify TLS fingerprints (pin-on-first-use or QR code), and authenticate with bearer tokens. Connections without a trusted fingerprint are rejected, including legacy fingerprint-less pairings. Plain `ws://` is available only through an explicit Debug-only loopback test override, never as an app fallback.
- **Local-first mirror.** The app maintains a local cache of workspaces, notes, and agent sessions for offline read access, synced via WebSocket JSON-RPC push notifications.
- **JSON-RPC client.** Talks to `intentd`'s WebSocket transport using the same JSON-RPC 2.0 protocol the desktop client uses.
- **Workspace tools.** Create and transfer workspaces, review staged and unstaged changes and commit diffs, browse workspace files, run and monitor workspace scripts, use workspace terminals, and open browser previews served through the daemon.
- **Pull requests.** Switch the workspace list to pull requests from its overflow menu (iPad: the Pull Requests sidebar section), filter and search them, and open a detail page with checks, reviews, and changed files.
- **Rich content.** Render Markdown, tables, attachments, and offline Mermaid diagrams in notes and conversations. Messages, question answers, and new workspaces accept up to 10 images.

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
├── AppIcon.icon               Icon Composer app icon
├── Assets.xcassets            App icon sets, colors, and Intent icons
├── Resources/                 Inter fonts, Lottie animations, and offline
│                              Mermaid and syntax-highlighting assets
├── Constants.swift, Models.swift
├── Info.plist, Intent.entitlements
├── PrivacyInfo.xcprivacy      Privacy manifest
├── ConnectionRegistryReadResult.swift
├── PersistenceKeychainStorage.swift
└── PersistenceManager*.swift  Keychain credentials, cached state, drafts, and preferences
Info-visionOS.plist            visionOS Info.plist
IntentTests/                   Unit and integration tests
IntentUITests/                 UI and screenshot tests
TailcatKit/                    Go bridge for iOS Tailcat tunnels
scripts/                       Build/test/lint wrappers, CI helpers, and
                               Mermaid/highlighting vendoring tools
.github/                       CI workflows, runner selection, and actions
ci_scripts/                    Xcode Cloud dependency preparation
```

The app uses **Network.framework** `NWConnection` for TCP/TLS (certificate pinning and path observation) and performs the RFC 6455 WebSocket upgrade and framing itself, negotiating **permessage-deflate** compression (`NWProtocolWebSocket` cannot accept server extensions). It uses **Textual** for Markdown, **SwiftTerm** for terminal emulation, and **Lottie** for bundled animations. Mermaid diagrams render through bundled **Pele** JavaScript in a `WKWebView`, without a CDN or runtime Node dependency.

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
- attachment upload, placement, and download, plus workspace file listing and reading;
- repository, branch, provider, model, specialist, and workspace skill discovery;
- Git status, diffs, and commit history across workspace repositories;
- GitHub authentication status and pull request search, detail, checks, reviews, and files;
- workspace transfer and mobile terminal lifecycle, input, output, and resizing;
- workspace script creation, start/stop, status, and removal; and
- background-hook, script-monitor, and pull-request-monitor status and controls.

Live updates combine domain subscriptions for workspaces, notes, tasks, comments, and chats—delivered as `subscription.push` notifications—with filtered `events.subscribe` streams for agent, hook, and pull-request-monitor events.
Browser previews use an auxiliary authenticated WebSocket tunnel rather than
passing daemon credentials to web content.

The workspace browser also opens HTTP and HTTPS addresses reachable from the
device, including LAN IP addresses, local hostnames, and Tailscale hostnames.
Allow Intent's local network access when prompted. The app declares an App
Transport Security exception for web content so user-entered HTTP sites can
load; daemon connections still require pinned WSS/TLS.

In an agent conversation, type `/` in the prompt to browse available workspace
skills. Matching skills appear as a horizontally scrolling row of chips above the
composer; keep typing to filter by name or description, then tap a chip to insert
its slash command. Hardware keyboards can use Up/Down to move the highlight, Tab
to insert, and Escape to dismiss the chips. Each agent's skill list is cached for
the rest of the app session.

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

### Offline Mermaid rendering with Pele

`Intent/Resources/Mermaid/` contains the checked-in Pele **1.8.0** engine in
`pele.bundle.js`, the renderer, licenses, and `vendor.json` provenance. Pele
replaces the Mermaid/ELK engine while retaining Mermaid source syntax and the
existing resource and vendoring directories. Normal Xcode builds use those
assets directly; Node/npm is only needed to regenerate them or run the
renderer's tests.

The engine exposes synchronous `window.intentPele.render(source, options)`.
The app's `window.renderMermaid` bridge still prepares local Inter fonts,
discards stale revisions, and reports height or errors to Swift. Diagrams keep
their natural size and source direction, with horizontal scrolling and pinch
zoom for wide content. Light and dark themes use Intent brand colors through
Pele CSS variables, using the palette and radii from the
[Intent Brand System](https://www.figma.com/design/yMkewdoHbGpIqVvZO09oA2/Intent-Brand---Working?node-id=2753-15362).
Links and images are disabled; source is limited to 50,000 characters and
flowchart/agentflow diagrams to 500 edges. Source directives and frontmatter
cannot relax those restrictions. The page's CSP and native navigation policy
continue to prevent external content access.

Pele uses its own layout and SVG structure; Mermaid layout engines and
`themeVariables` do not carry over. Labels support text formatting rather than
arbitrary HTML. TeX labels show their source because no math typesetter is bundled.

To regenerate the bundle from its locked dependencies:

```bash
cd scripts/vendor-mermaid
npm ci
npm run build
```

Review the lockfile, generated bundle, license notices, and `vendor.json` together. To test
the shipped renderer from the same directory, run `npx playwright install chromium webkit`
then `npm test`. The browser suite covers flowchart, sequence, state, class, ER,
pie, XY chart, Gantt, Git graph, and frontmatter fixtures in both themes, plus
security, source and edge limits, stale requests during font loading, source directions,
natural-size scrolling, fullscreen sizing, and completion without animation
frames. Set `MERMAID_BROWSERS=chromium` or `MERMAID_BROWSERS=webkit` for a focused
run. To capture all fixtures in both themes, set `MERMAID_SCREENSHOT_DIR` to a
directory outside the checkout, for example:

```bash
MERMAID_SCREENSHOT_DIR=/tmp/intent-pele-screenshots npm test
```

Screenshot names include the engine, browser, fixture, and appearance. Review
the images before claiming visual coverage; browser screenshots do not replace
native device or simulator validation. Native coverage lives in `MermaidMarkdownContentTests`,
`MermaidWebViewTests`, and `ConversationMermaidUITests`.
The native Mermaid probes have a five-second JavaScript deadline and require a
successful render before inspecting the page. `MermaidJavaScriptProbeTests`
checks missing and late callbacks, error propagation, and cancellation without
depending on a healthy WebKit process. CI retains unit results and console logs
on cancellation as well as failure so interrupted renderer runs can be inspected.

### Offline file syntax highlighting with Pierre

File previews and workspace diffs use **@pierre/highlights 0.3.0**, bundled in
`Intent/Resources/Highlights/` with its WebAssembly engine, Pierre Light/Dark
themes, full license notices, and `vendor.json` checksums. The published package
contains 120 syntax lexers plus plain text. Normal app builds use the checked-in
assets; no Node installation, CDN, or grammar downloads are needed at runtime.

The local page exposes asynchronous
`window.intentHighlights.highlight({ source, path, dark })`, returning
`{ language, runs: [{ location, length, color, fontStyle }] }`. Ranges use UTF-16
code units in the unchanged source, colors are six-digit hex RGB, and font styles
use Shiki flags. `ready` resolves to a boolean; `status` is `loading`, `ready`, or
`failed`. Source text is never inserted into the page. CSP blocks network access
and JavaScript evaluation while permitting the bundled WebAssembly engine.

Unknown filenames, engine failures, source above 512 KiB UTF-8, lines above
10,000 UTF-16 code units, or output above 60,000 runs return empty runs for native
plain-text fallback. These are prototype highlighting limits, independent of
the existing 5 MiB file-opening limit. A shared, nonpersistent `WKWebView`
returns token ranges to the native TextKit 2 viewer. Only foreground colors
change, preserving font metrics, text selection, scrolling, and original-file
contents. Requests cancel on file/theme changes or dismissal and fall back after
five seconds; JavaScript cannot interrupt synchronous WebAssembly tokenization.

File previews include a native line-number gutter, 8-point horizontal padding,
and 16-point vertical padding.
The header uses the shared sidebar tint, a flat Back action, and a file-options
menu with Copy contents, Copy path, Wrap lines, and Show line numbers. Copy uses
the original source text or workspace file path. Both display toggles are on by
default and remembered across previews; turning wrapping off enables horizontal
scrolling with a pinned line-number gutter. Hiding numbers reclaims the gutter's
width while preserving the reading position and selection.
Numbers follow source lines, including blank lines and a final empty line;
wrapped continuations do not repeat numbers. The gutter uses visible TextKit 2
layout fragments and stays outside the selectable/shared text. Source line
offsets are indexed during background file loading.

Diffs retain native old/new numbers, markers and change backgrounds. Commit
diffs tokenize the complete old and new sources separately. Working and staged
diffs only receive hunks from the daemon, so each contiguous side starts with
fresh lexer state; a comment or string that begins in omitted context can have
incomplete colors. Unknown or over-budget diffs remain plain. Theme and file
changes cancel highlighting and discard stale results.

Commit viewing uses one vertically scrolling Changes page with collapsible file
sections and independently scrolling horizontal diffs. Each filename stays pinned
above its diff until the next file header takes its place. A floating Jump to file
control appears only while a file section is not fully visible, and opens a
searchable half sheet (expandable to full height; full height at
accessibility text sizes) and expands the chosen section. Changes and Details use
the same switcher as workspace content. The Details tab exposes the available message,
author, date, copyable full hash, and known push status; switching tabs preserves
the Changes scroll position. Associated PRs and parent links are not supplied by
the current commit model. On iPad, commits and staged/unstaged file diffs open in
the main content pane from either the overview or workspace sidebar, using the shell’s background
colors. Back preserves the previous page and repository selection; changing
workspaces or repositories closes the viewer.

Regenerate and verify the assets with Node 24 or newer:

```bash
cd scripts/highlights
npm ci
npm run build
npx playwright install chromium webkit
npm test
```

The suite checks the shipped bundle, filename resolution, Unicode/CRLF offsets,
multiline syntax, both themes, budgets, WebAssembly failure, and offline CSP in
Chromium and WebKit. `HIGHLIGHTS_BROWSERS=webkit npm test` selects one browser.
Review generated assets, notices, provenance and the lockfile together. Browser
tests validate the tokenizer contract; native screenshots and device timings
remain separate evidence for the prototype.

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
depends on `ldd` even though it stubs the reported operating system, a
documented Linux-only limitation ([ios#733](https://github.com/intent-hq/ios/issues/733), closed).

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
| `build-ios-device` | Build for physical `DEVICE_UDID` using project signing; does not install, upload, or change provisioning. |
| `build-visionos` | Build for the generic visionOS Simulator destination. |
| `build-for-testing` | Build the iOS test bundles for a later test-only run. |
| `build-for-testing-ui` | Build the app and UI tests using the `IntentUI` scheme, without compiling the unit-test bundle. |
| `test-without-building` | Run previously built unit and UI tests. |
| `test-without-building-ui` | Run UI tests built with `build-for-testing-ui`; exclude unit tests from enumeration and execution. Defaults `ONLY_TESTING` to `IntentUITests` and verifies the selected results. |
| `test-without-building-unit` | Run previously built tests without `IntentUITests`. |
| `test-ios` | Build and run the complete unit and UI test gate. |
| `test-ios-unit` | Build and run tests without `IntentUITests`. |
| `pick-simulator` | Print the automatically selected iPhone simulator UDID. |

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

To test one commit on a Mac, for example for an agent working on Linux, use
`scripts/run_commit_tests.sh`. It checks the commit out into a clean temporary
directory (fetching it from `origin` if needed), runs the selected tests through
the wrapper, and writes a summary to
`~/Library/Caches/intent-ios-test-run/summary.md`. The summary gives the verdict,
per-suite executed, passed, failed and skipped counts, each failing test with its
first failure message, the log path, and a command that repeats the run. Any
`IntentUITests` selector runs `test-ios`; otherwise it runs `test-ios-unit`:

```bash
scripts/run_commit_tests.sh <full-sha> 'IntentTests/AgentListPagingTests'
```

The exit status is the wrapper's. Run it in the foreground. See the script header for
the files it keeps and the environment it passes through.

The `build-visionos` command always uses the generic visionOS Simulator destination,
never `-sdk`: an `-sdk xros...` invocation can silently fall back to `iphoneos` when
the visionOS platform is absent and produce a bogus successful build.

Tests run **serially** by default — the shared `Intent` and `IntentUI` schemes pin `parallelizable = "NO"`, so no extra flags are needed. Parallel simulator clone runners mass-flake the suite locally (see [intent-hq/intent#759](https://github.com/intent-hq/intent/issues/759)).

### CI and review evidence

`.github/workflows/ci.yml` runs unit tests, the UI smoke selectors in
`scripts/ui-smoke-tests.txt`, and a visionOS build for pull requests and the merge
queue. Smoke coverage uses two balanced iPhone shards and an independent job for
all eleven focused iPad regressions: sidebar and rail navigation, search, the
Pull Requests section, the empty detail-pane placeholder, and commit and file
diff viewing in the main pane. Each lane owns its build directory,
disposable simulator, results, and evidence. All lanes prefer an idle
self-hosted Mac; GitHub-hosted Macs handle overflow when the local pool is busy.
Matrix fail-fast is
disabled, and the existing `iOS UI Tests` check requires every lane to succeed.
Go tests, wrapper self-tests, and the strict SwiftLint gate run on Linux.
The full UI bundle runs across two isolated iPhone shards, alongside the iPad regressions,
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
suffixes for smoke and full runs. Simulator and failure
artifacts also include the lane name.

Full shards partition the built runnable inventory through `scripts/ui_full_tests.py`.
Measured suite durations in `scripts/ui-full-test-durations.json` guide balancing;
new suites use a per-test estimate and are always included. Each test belongs to
exactly one shard, and each suite stays together. The aggregate job compares both
lanes' inventories, plans, tested revisions, and resolved identities before passing.
Scheme exclusions and runtime quarantines remain in force. Only the first iPhone
shard owns the screenshot lifecycle contract. Logs and selection plans are retained
in `ios-iphone-1-ui-selection` and `ios-iphone-2-ui-selection`; failed or cancelled
lanes retain their available result bundles. An interrupted bundle can remain unreadable.

After building with `build-for-testing-ui`, select a full shard locally with
`UI_TEST_SHARD=1 scripts/xcodebuild.sh test-without-building-ui` (or `2`). It cannot
be combined with a narrower `ONLY_TESTING`. Use `UI_TEST_SHARD_PLAN_PATH` and
`ONLY_TESTING_IDENTITIES_PATH` to retain selection evidence. Run
`python3 scripts/test_ui_full_tests.py` after changing the partitioner or its timing data.

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
skips. Quarantined transcript cases in
[`ConversationTranscriptFullGateUITests.swift`](IntentUITests/ConversationTranscriptFullGateUITests.swift)
extend `ConversationTranscriptScrollUITests`. Select
`ONLY_TESTING='IntentUITests/ConversationTranscriptScrollUITests'` with
`TEST_RUNNER_INTENT_UITEST_FULL_GATE_REPRO=1` on a local wrapper run;
`ui_suite=full` alone does not opt into them.

#### Mermaid UI quarantine

`IntentUITests/ConversationMermaidUITests/testFullscreenButtonEdgeAndInlinePinchAndPan`
is quarantined for intermittent inline and fullscreen render failures first reported in
[ios#735](https://github.com/intent-hq/ios/issues/735). That issue was closed as stale
after repeated passing filtered runs, but the guard remains; lifting it is tracked in
[ios#940](https://github.com/intent-hq/ios/issues/940). The root cause is unconfirmed.
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
Remove the guard and restore the smoke selector together (ios#940) after a
validated fix and repeated unchanged runs pass on the affected CI simulator/Xcode
configurations with the original assertions and timeouts.

### UI evidence artifacts

CI uploads `ios-ui-review-evidence` for 14 days when allowlisted captures exist,
on success or failure and for filtered UI runs. Open its PNGs directly;
`manifest.json` records the tested revision, suite/test, source bundle, and retry
origin. UI lane exports append the lane name (`-iphone-1`, `-iphone-2`, or `-ipad`),
for example `ios-ui-review-evidence-ipad`, to avoid collisions; filtered and
`pre_pr_gate` dispatches upload the unsuffixed `ios-ui-review-evidence`. Captures
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
`python3 scripts/check_ui_attachment_lifecycle.py` and its mutation tests
(`scripts/test_check_ui_attachment_lifecycle.py`) to
reject attachment-producing defer blocks (including named helper calls);
ordinary cleanup remains allowed. The source check is conservative by function
name, not a Swift type checker: it includes parameter defaults but does not
resolve dynamic dispatch, aliases, computed properties, or constructors.

After `scripts/xcodebuild.sh build-for-testing-ui`, run
`python3 scripts/verify_fixture_capture_lifecycle.py --output-root build/capture-contract`
with the same simulator and derived-data settings. The output directory must be
new. The first iPhone shard in both smoke and full runs owns this contract
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

Other repository checks: `scripts/test-row-provider-isolation.sh` compiles positive
and negative SwiftUI fixtures against the deferred row-provider boundary on the macOS
CI job. On Linux, `python3 scripts/protocol_fixture_version.py lint` keeps test
`client.hello` fixtures on the current intentd protocol version (`check` warns when
`IntentTests/CurrentProtocolVersion.swift` is behind; `sync` updates it), with
`python3 scripts/test_protocol_fixture_version.py` as its contract test, and
`python3 scripts/test_fixture_capture_lifecycle.py` rejects false greens in the
capture-lifecycle verifier. `scripts/generate-inter-instances.py` rebuilds the bundled
static Inter faces from the pinned Inter release (see its header for the command).
The Linux job also runs the offline tooling self-tests `scripts/test_xcodebuild.sh`,
`scripts/test_run_commit_tests.sh`,
`scripts/test-ci-post-clone.sh`, `scripts/test-check-swiftlint-inputs.sh`,
`scripts/test-update-source-lists.sh`, `scripts/test-generate-test-inputs.sh`, and `python3 scripts/test_select_macos_runner.py`;
`scripts/check-swiftlint-inputs.sh` keeps `scripts/swiftlint-xcode-inputs.xcfilelist`
in sync with the Swift sources; `scripts/update-source-lists.sh` regenerates it and
`scripts/test-source-inputs.xcfilelist` after Swift files are added, split, moved, or removed.

Two auxiliary workflows run on pushes to `main`: `warm-cache.yml` (also weekly on
Mondays at 06:17 UTC and on manual dispatch) seeds the Go, TailcatKit, and SPM caches
that `ci.yml` restores, and `notify-monorepo.yml` sends a fail-soft
`repository_dispatch` so intent-hq/intent can advance its submodule pin.

Xcode Cloud uses `ci_scripts/ci_post_clone.sh` to prepare TailcatKit for iOS with
a checksum-pinned Go toolchain; it skips that setup for visionOS. This is build
preparation, not release automation. See [AGENTS.md](AGENTS.md#releases) for
version/build-number checks and the human-controlled upload and release policy.

### GitHub Actions runners

Script and Go jobs use GitHub-hosted `ubuntu-24.04`. All macOS jobs prefer
self-hosted Macs: iOS builds and every iPhone/iPad UI lane use the `intent-ios`
pool; visionOS builds and cache warming prefer `intent-ios-build`, then
`intent-ios`. Each pool selects its installed Xcode independently.
The 18 October 2026 validation used Xcode 26.5 on a Depot Mac (the hosted pool
before the move to GitHub-hosted runners) for iPad and 26.3 on the local iPhone Mac.
The pools do not guarantee the same toolchain or simulator runtime. Record the
runner, Xcode, and runtime when comparing timings or investigating failures.
Selectors (`.github/scripts/select-macos-runner.sh`) use `RUNNER_STATUS_TOKEN` to inspect the pools and fall back to
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
