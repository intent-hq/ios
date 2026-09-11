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

```bash
# 1. Open in Xcode
open Intent.xcodeproj

# 2. Select a simulator or device target (iPhone, iPad, or Apple Vision Pro)

# 3. Build and run (Cmd+R)
#    - The app will show the pairing screen
#    - On your Mac, run: intentd serve --listen tcp

# 4. Scan the QR code from the desktop app or enter the token manually

# 5. Once paired, the app shows the workspace list
```

The app requires an `intentd` instance with its TCP WebSocket listener enabled:

```bash
intentd serve --listen tcp
```

## Dependencies

Managed via Swift Package Manager (integrated in Xcode):

- **[Textual](https://github.com/intent-hq/textual)** `0.5.0-intent.2` (exact) — Markdown rendering for notes and messages

## Development

```bash
# Build in Xcode (Cmd+B) or via xcodebuild
xcodebuild -project Intent.xcodeproj -scheme Intent -destination 'platform=iOS Simulator,name=iPhone 16' build

# Run tests
xcodebuild -project Intent.xcodeproj -scheme Intent -destination 'platform=iOS Simulator,name=iPhone 16' test

# Build for visionOS
xcodebuild -project Intent.xcodeproj -scheme Intent -destination 'generic/platform=visionOS Simulator' CODE_SIGNING_ALLOWED=NO build
```

Always verify visionOS with the `generic/platform=visionOS Simulator` destination, **never** with `-sdk xros26.5` (or `-sdk xrsimulator26.5`): when the visionOS platform component is not installed, `-sdk xros...` **silently falls back to building against iphoneos** (`PLATFORM_NAME = iphoneos`), producing a bogus "build succeeded". Install the platform first with `xcodebuild -downloadPlatform visionOS`; the destination form then resolves correctly (and errors out instead of falling back when the platform is missing).

Tests run **serially** by default — the shared `Intent` scheme pins `parallelizable = "NO"`, so no extra flags are needed. Parallel simulator clone runners mass-flake the suite locally (see [intent-hq/intent#759](https://github.com/intent-hq/intent/issues/759)).

**Conventional commits** are required (`feat`, `fix`, `chore`, `docs`, `refactor`, `test`, `ci`, `perf`); PR titles are validated in CI.

## Related Repositories

- [intent-hq/intent](https://github.com/intent-hq/intent) — engineering monorepo that mounts this repo at `packages/ios`, holds the cross-cutting docs and tooling, and hosts the central [issue tracker](https://github.com/intent-hq/intent/issues).
- [intent-hq/intentd](https://github.com/intent-hq/intentd) — Rust backend daemon this app connects to.

## License

This project is licensed under the [Apache License 2.0](LICENSE).
