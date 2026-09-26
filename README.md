# ios

The **Intent companion app** is a native SwiftUI client for iPhone, iPad, and Apple Vision Pro that connects to the `intentd` daemon over WebSocket (**WSS/TLS** when a certificate fingerprint is pinned, plain `ws://` otherwise). It provides on-the-go access to workspaces, notes, tasks, and agent conversations from any Intent-enabled desktop on your local network.

## What it is

- **Native SwiftUI.** Built for iOS 18.0+ / visionOS 2.0+ with async/await, SwiftUI lifecycle, and `@MainActor` isolation. Supports iPhone, iPad, and Apple Vision Pro form factors — visionOS is a destination of the single `Intent` target, not a separate target.
- **Secure pairing.** Pair with `intentd` via **QR code (iPhone/iPad), `intent://pair` deep link, or manual entry**, verify TLS fingerprints (pin-on-first-use or QR code), and authenticate with bearer tokens. Traffic is **WSS/TLS** when a certificate fingerprint is available; new pairings always pin a fingerprint (manual entry aborts when the TLS probe finds no certificate), and only legacy fingerprint-less pairings still use plain `ws://`.
- **Local-first mirror.** The app maintains a local cache of workspaces, notes, and agent sessions for offline read access, synced via WebSocket JSON-RPC push notifications.
- **JSON-RPC client.** Talks to `intentd`'s WebSocket transport using the same JSON-RPC 2.0 protocol the desktop client uses.

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
├── Resources/                 Bundled media (splash asset)
├── Constants.swift, Models.swift
├── PrivacyInfo.xcprivacy      Privacy manifest
└── PersistenceManager.swift   Keychain credentials, cached state, and preferences
IntentTests/                   Unit and integration tests
IntentUITests/                 UI and screenshot tests
```


The app uses **Network.framework** (`NWConnection` + `NWProtocolWebSocket`) for WebSocket transport and **Textual** for rendering notes and conversation messages.

## Pairing

On first launch, the app shows a pairing flow:

1. **QR, deep link, or manual entry**: the user scans a QR code from the desktop app containing the host, port, token, and cert fingerprint, opens an `intent://pair` deep link, or enters them manually. On visionOS there is no QR path (no third-party camera access): pairing is deep link or manual entry only.
2. **TLS fingerprint verification**: the app computes the SHA-256 fingerprint of the server's self-signed certificate and compares it to the expected fingerprint (from QR or prompt). On mismatch, connection is rejected.
3. **Bearer auth**: the token is sent in the `Authorization: Bearer <token>` header.
4. **Persist credentials**: the token, server info, and paired connections are stored in the **Keychain**; non-secret UI state (active connection id, drafts, last-screen navigation) is kept in `UserDefaults`.

## visionOS

Apple Vision Pro support is a **destination of the single `Intent` target**: `SUPPORTED_PLATFORMS` includes `xros`/`xrsimulator`, `TARGETED_DEVICE_FAMILY` includes `7`, and `XROS_DEPLOYMENT_TARGET` is `2.0`. Every view, store, and service compiles for visionOS by default; platform differences live behind `#if os(visionOS)` guards. CI keeps the destination green with a dedicated `visionos-build` job (build only, no tests).

Platform limitations on visionOS:

- **No tunnel pairing.** `TailcatKit.xcframework` has no xros slice (gomobile has no visionOS target), so the framework is linked for iOS only and the tunnel path reports an explicit "unavailable" error on visionOS. Connections are LAN only, paired via `intent://pair` deep link or manual entry.
- **No QR scanning.** visionOS grants no third-party camera access, so the QR pairing path is hidden.

`TailcatKit/build_xcframework.sh` builds the (gitignored) xcframework for the iOS slices. When the system Go is older than the version in `go.mod`, pin the toolchain explicitly, e.g. `GOTOOLCHAIN=go1.27.0 ./TailcatKit/build_xcframework.sh` — without the pin, gomobile fails resolving the bare `go1.27` toolchain alias.

## JSON-RPC Surface

The app uses the daemon's namespaced JSON-RPC API for these capability groups:

- workspace discovery, creation, lifecycle actions, and live state;
- note and comment reading and live state, plus task listing, status changes, and live state;
- agent discovery and lifecycle plus conversation history, sending, queue management, questions, models, and streaming controls;
- attachment upload, placement, and download;
- repository, branch, provider, model, and specialist discovery; and
- background-hook and pull-request-monitor status and controls.

Live updates combine domain subscriptions for workspaces, notes, tasks, comments, and chats—delivered as `subscription.push` notifications—with filtered `events.subscribe` streams for agent, hook, and pull-request-monitor events.

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

Managed via Swift Package Manager (integrated in Xcode):

- **[Textual](https://github.com/intent-hq/textual)** `0.5.0-intent.2` (exact) — Markdown rendering for notes and messages

## Development

### Clean-checkout prerequisites

- For app builds: macOS with Xcode and its command-line tools. Tests require an available iPhone
  simulator.
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
| macOS with Xcode (native CI: macOS 15, arm64) | Existing SwiftLint 0.65.1 on `PATH` and Xcode toolchain; unchanged invocation. |
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

# Offline wrapper, prerequisite, and setup regressions.
scripts/test-swiftlint.sh
scripts/test-swiftlint-prerequisites.sh
scripts/test-setup-swiftlint.sh
```

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
| `test-without-building` | Run previously built unit and UI tests. |
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

Use the non-unit variants when selecting `IntentUITests`. `SIM_UDID` selects a
specific simulator; otherwise the wrapper chooses one and serializes test runs on
that device.

The `build-visionos` command always uses the generic visionOS Simulator destination,
never `-sdk`: an `-sdk xros...` invocation can silently fall back to `iphoneos` when
the visionOS platform is absent and produce a bogus successful build.

Tests run **serially** by default — the shared `Intent` scheme pins `parallelizable = "NO"`, so no extra flags are needed. Parallel simulator clone runners mass-flake the suite locally (see [intent-hq/intent#759](https://github.com/intent-hq/intent/issues/759)).

**Conventional commits** are required (`feat`, `fix`, `chore`, `docs`, `refactor`, `test`, `ci`, `perf`); PR titles are validated in CI.

## Related Repositories

- [intent-hq/intent](https://github.com/intent-hq/intent) — engineering monorepo that mounts this repo at `packages/ios` and holds cross-cutting docs and tooling.
- [intent-hq/intentd](https://github.com/intent-hq/intentd) — Rust backend daemon this app connects to.

Report bugs and limitations in the iOS app to the
[intent-hq/ios issue tracker](https://github.com/intent-hq/ios/issues), not the
monorepo issue tracker.

## License

This project is licensed under the [Apache License 2.0](LICENSE).
