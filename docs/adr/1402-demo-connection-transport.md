# ADR-1402: The demo transport feeds fixtures through the real connection path

- Status: Accepted
- Recorded: 2026-11-20 (moved from code comments; the decisions are older)
- Applies to: `DemoConnectionTransport` and the `ConnectionManager` demo extensions (`Intent/Demo/DemoConnectionTransport.swift`), `DemoScriptMonitorFixtures` (`Intent/Demo/DemoScriptMonitorFixtures.swift`)

## Context

Demo sessions have no socket. `DemoConnectionTransport` answers requests with
fixture responses and scripted script-monitor events, and pushes chat
snapshots. The rest of the app must see the same order of events as with a
live daemon.

## Decisions

### 1. Demo sessions use fixture pushes instead of a socket's feed, with the same readiness transitions

Applies to: `ConnectionManager.connectDemo(serveFixtures:)`

The demo connection is Debug-only. Readiness stays tied to the same connection
transitions as the stores that consume it.

### 2. The transport is Debug-only and compiled out of Release

Applies to: `DemoConnectionTransport`

Release builds compile it out with the rest of `Intent/Demo/`.

### 3. Every `--demo-data` connection serves fixtures; script monitors need an explicit fixture connection

Applies to: `DemoConnectionTransport.make(serveFixtures:arguments:)`

`--demo-data` launches serve fixtures from every connection. Only an explicit
fixture connection (`serveFixtures`) also enables scripted script monitors.

### 4. Startup UI tests admit the real daemon's principal, and a scripted drop clears the demo principal

Applies to: `DemoConnectionTransport.principal`, `DemoConnectionTransport.isDropped`

Startup UI tests admit the real loopback daemon's principal instead of the demo
owner. Like production, a scripted drop clears the live principal until
recovery.

### 5. Startup UI tests get fixtures only after a fresh daemon hello

Applies to: `DemoConnectionTransport.response(for:params:on:)`

While `DemoStartupConnection.isEnabled` and the connection is not connected,
requests fail with the not-connected error.

### 6. Subscription pushes are routed before the acknowledgement returns

Applies to: `DemoConnectionTransport.response(for:params:on:)`

The push is routed ahead of the ack. The subscription router buffers it until
the caller registers its handler. A live daemon can produce the same order.

### 7. `demoScriptMonitorFixtures` is a test convenience

Applies to: `ConnectionManager.demoScriptMonitorFixtures`

It returns the scripted script-monitor fixture of the installed demo transport,
if any.

### 8. The script-monitor fixture is a passive wire fixture

Applies to: `DemoScriptMonitorFixtures`

It is an explicit demo-only wire fixture. Its single event pump feeds the
normal `ConnectionManager` handlers. It never mutates a store or a view, and it
never polls a server.

### 9. `consume(_:)` returns the full transient lifecycle envelope

Applies to: `DemoScriptMonitorFixtures.consume(_:)`

Like the daemon, it returns the full transient lifecycle envelope. Tests can
also drive it synchronously to verify the fixture's wire contract.
