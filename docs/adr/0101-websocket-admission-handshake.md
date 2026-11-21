# ADR-0101: Admission runs on a bootstrap socket and a startup wait always reconnects

- Status: Accepted
- Recorded: 2026-11-20 (moved from code comments; the decisions are older)
- Applies to: `WebSocketConnection.admittedHandshake`, `WebSocketConnection.awaitStartup`
  (`Intent/Services/WebSocketAdmission.swift`)

## Context

Before a socket joins the app, it sends `client.hello` and `principal.me`. The
daemon can reject the hello while it is still starting, and then the app polls
`system.startupStatus`.

## Decisions

### 1. Bootstrap sockets stay outside the message pump

Applies to: `WebSocketConnection.admittedHandshake`

Admission requests run on the socket before the app's message pump owns it.
Even a ready startup snapshot retires this socket. Only a fresh hello can admit
a principal, so after any startup wait `admittedHandshake` throws
`DaemonStartupError.reconnect`.

### 2. A failed poll reconnects without replay

Applies to: `WebSocketConnection.awaitStartup`

When a startup poll fails, `awaitStartup` reports `.unavailable` and throws
`DaemonStartupError.reconnect`. This covers close-on-ready and failed or
timed-out polling. No cached progress stays current, and no mutation is
replayed.
