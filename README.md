# ios

The **Intent iOS companion app** is a native SwiftUI client for iPhone and iPad that connects to the `intentd` daemon over WebSocket (**WSS/TLS** when a certificate fingerprint is pinned, plain `ws://` otherwise). It provides on-the-go access to workspaces, notes, tasks, and agent conversations from any Intent-enabled desktop on your local network.

> ⚠️ Private Repository — This repo is internal to the Cloudlands engineering team. It is consumed as a git submodule by [intent-hq/monorepo](https://github.com/intent-hq/monorepo).

**Provenance:** Originally imported from [augmentcode/intent#276](https://github.com/augmentcode/intent/pull/276).

## What it is

- **Native SwiftUI.** Built for iOS 26.2+ with async/await, SwiftUI lifecycle, and `@MainActor` isolation. Supports both iPhone and iPad form factors.
- **Secure pairing.** Pair with `intentd` via **QR code or manual entry**, verify TLS fingerprints (pin-on-first-use or QR code), and authenticate with bearer tokens. Traffic is **WSS/TLS** when a certificate fingerprint is available; the app falls back to plain `ws://` when none is known (e.g., manual pairing without a fingerprint).
- **Local-first mirror.** The app maintains a local cache of workspaces, notes, and agent sessions for offline read access, synced via WebSocket JSON-RPC push notifications.
- **JSON-RPC client.** Talks to `intentd`'s WebSocket transport using the same JSON-RPC 2.0 protocol the desktop client uses.

## Architecture

A single-target Xcode project with a SwiftUI app, structured as:

```text
Intent/
├── IntentApp.swift         Entry point + theme preference
├── AppCoordinator.swift    Navigation coordinator
├── RootView.swift          Root view switcher (pairing / main UI)
├── ContentView.swift       Main UI (workspace list + detail)
├── Theme.swift             Color palette + shared styling
├── Models/                 Codable domain models (Note, AgentSession, etc.)
├── Services/               Business logic + JSON-RPC client
│   ├── ConnectionManager.swift   WebSocket connection lifecycle + request/response
│   ├── WorkspaceStore.swift      Workspace CRUD + caching
│   ├── NoteStore.swift           Note CRUD + caching
│   ├── AgentStore.swift          Agent session tracking
│   ├── ConversationStore.swift   Message history + streaming
│   └── CoverflowStore.swift      Coverflow UI state (archived workspace flow)
├── Views/                  SwiftUI components
│   ├── PairingView.swift         Initial pairing flow orchestrator
│   ├── QRScannerView.swift       QR code scanner for token + fingerprint
│   ├── ManualTokenEntryView.swift  Manual token entry
│   ├── WorkspaceListView.swift   Workspace list (main screen)
│   ├── WorkspaceDetailView.swift Workspace detail (notes + agents)
│   ├── NoteListView.swift        Note list
│   ├── NoteDetailView.swift      Note viewer (Markdown rendering)
│   └── ...                       (LoadingView, DisconnectedView, ToastView, etc.)
├── ViewModels/             ObservableObject view models
│   ├── WorkspaceListViewModel.swift  Workspace list state
│   ├── ConversationViewModel.swift   Agent conversation state
│   └── AgentListViewModel.swift      Agent list state
├── Utils/
│   ├── HapticManager.swift       Haptic feedback
│   └── NotificationManager.swift Local notifications
└── PersistenceManager.swift      Local storage (UserDefaults + JSON cache)
```


The app uses **Starscream** for WebSocket transport and **MarkdownUI** for rendering notes and conversation messages.

## Pairing

On first launch, the app shows a pairing flow:

1. **QR or manual entry**: the user scans a QR code from the desktop app containing the host, port, token, and cert fingerprint, or enters them manually.
2. **TLS fingerprint verification**: the app computes the SHA-256 fingerprint of the server's self-signed certificate and compares it to the expected fingerprint (from QR or prompt). On mismatch, connection is rejected.
3. **Bearer auth**: the token is sent in the `Authorization: Bearer <token>` header.
4. **Persist credentials**: host, port, token, and fingerprint are saved to `UserDefaults` for reconnection.

## JSON-RPC Surface

The app calls a subset of the `intentd` JSON-RPC API:

| Namespace | Methods |
| --- | --- |
| `workspace.*` | `list`, `read`, `create` (limited subset for mobile) |
| `note.*` | `list`, `read`, `create`, `update` (viewing + creation only) |
| `task.*` | `list`, `update` (task status toggling) |
| `agent.*` | `list`, `getConversation`, `sendMessage` (read + send only) |
| `events.*` | `subscribe`, `unsubscribe` (for push notifications) |

The app subscribes to `events.event` notifications and updates its local cache when workspaces, notes, or agents change on the backend.

## Quickstart

```bash
# 1. Open in Xcode
open Intent.xcodeproj

# 2. Select a simulator or device target (iPhone or iPad)

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

- **[Starscream](https://github.com/daltoniam/Starscream)** `^4.0.8` — WebSocket client for WSS/TLS transport
- **[swift-markdown-ui](https://github.com/gonzalezreal/swift-markdown-ui)** `^2.4.0` — Markdown rendering for notes and messages

## Development

```bash
# Build in Xcode (Cmd+B) or via xcodebuild
xcodebuild -project Intent.xcodeproj -scheme Intent -destination 'platform=iOS Simulator,name=iPhone 16' build

# Run tests
xcodebuild -project Intent.xcodeproj -scheme Intent -destination 'platform=iOS Simulator,name=iPhone 16' test
```

**Conventional commits** are required (`feat`, `fix`, `chore`, `docs`, `refactor`, `test`, `ci`, `perf`); PR titles are validated in CI.

## Related Repositories

- [intent-hq/monorepo](https://github.com/intent-hq/monorepo) — engineering monorepo that mounts this repo at `packages/ios` and holds the cross-cutting docs and tooling.
- [intent-hq/intentd](https://github.com/intent-hq/intentd) — Rust backend daemon this app connects to.
