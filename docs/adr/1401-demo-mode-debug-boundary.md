# ADR-1401: Demo mode is a Debug-only seam with production-safe flags

- Status: Accepted
- Recorded: 2026-11-20 (moved from code comments; the decisions are older)
- Applies to: `DemoMode` (`Intent/Demo/DemoMode.swift`), `DemoSettings` (`Intent/Demo/DemoSettings.swift`), `DemoStartupConnection` (`Intent/Demo/DemoStartupConnection.swift`)

## Context

Demo launches (`--demo-data`) use fixture data and ephemeral persistence
without pairing. UI tests and screenshots depend on them. Release builds must
not ship demo behavior.

## Decisions

### 1. Demo fixtures exist only in Debug builds; Release ignores the demo flags

Applies to: `DemoMode.isEnabled`, `DemoMode.pretendPaired`,
`DemoMode.demoDataRequested(by:)`, `DemoMode.pretendPairedRequested(by:)`

In Release the flags are always `false`. Demo entry points (fixtures,
`connectDemo`, launch probes) are Debug-only declarations, so a Release caller
fails to compile.

### 2. Code outside `Intent/Demo` reads the flags only to pick a production path

Applies to: `DemoMode`

Outside `Intent/Demo`, read these flags unguarded only to choose between
production paths: ephemeral storage, skipping sync, routing. Release's `false`
is the production answer there. Any read that reaches demo code sits in that
owner's single `#if DEBUG` seam.

### 3. Settings fixtures write only the ephemeral demo store

Applies to: `DemoSettings.seedConnectionsIfNeeded()`

`DemoSettings` seeds saved machines for Settings screenshots and interaction
tests. It writes only the existing ephemeral demo store. A normal launch is
untouched.

### 4. The seeded primary machine is consumed on the first window appearance only

Applies to: `DemoSettings.consumeStartupBackendID()`

Native scene restoration outlives the ephemeral demo records. The seeded
primary is consumed only on the first actual window appearance. Later
foregrounding and newly opened Travel windows keep their own selection.

### 5. Startup connection tests use the production connection path

Applies to: `DemoStartupConnection`

Debug UI tests seed a saved pinned loopback route, then use the production
`ConnectionManager` and the connecting and recovery views. Demo fixtures serve
only post-admission data. No progress state or connected flag is injected.
