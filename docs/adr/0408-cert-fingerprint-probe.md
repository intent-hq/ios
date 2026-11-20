# ADR-0408: Pairing probes the TLS certificate fingerprint with Network.framework

- Status: Accepted
- Recorded: 2026-11-20 (moved from code comments; the decisions are older)
- Applies to: `CertFingerprintProbe` (`Intent/Services/CertFingerprintProbe.swift`)

## Context

Manual token entry and QR pairing payloads without a fingerprint must learn the
server's certificate fingerprint before the app pairs. `CertFingerprintProbe`
reads it with a bare TLS handshake.

## Decisions

### 1. Pairing connections are always pinned

Applies to: `CertFingerprintProbe`, `CertFingerprintProbe.outcome(forProbe:)`

The probe is shared by manual token entry and by QR pairing payloads that carry
no fingerprint. A missing fingerprint aborts pairing. There is no fallback to
plain WS. An empty `.fingerprint` is the degenerate no-certificate case and
also aborts.

### 2. Network.framework, not URLSession

Applies to: `CertFingerprintProbe.makeProbeConnection(...)`

The probe uses `NWConnection`, like `WebSocketConnection`. URLSession is
deliberately not used: App Transport Security aborts the TLS handshake to
non-local hosts (public IPs, Tailscale) before the server-trust delegate runs,
so the fingerprint could never be captured for remote daemons. No HTTP request
is needed; the handshake alone yields the certificate.

### 3. Every failure keeps its stage and cause

Applies to: `CertFingerprintProbe.ProbeResult`, `CertFingerprintProbe.classify(captured:settled:cancelled:)`

Callers must tell an unreachable endpoint from a TLS problem, not collapse
everything into "no certificate". The result names the stage: timeout,
unreachable host, TLS handshake failure, or a handshake that presented no
certificate. `invalidPort` (outside 1...65535) and `noHosts` mean nothing was
dialed. `tlsFailed` means TCP connected but the handshake failed, for example
on a plain-TCP or HTTP listener. `unreachable` means the TCP connection never
came up (refused, unroutable, DNS).

### 4. Failure causes are safe to show in Release

Applies to: `CertFingerprintProbe.FailureCause`

The cause renders the `NWError` as a static domain name, the numeric code, and
a static label for well-known codes. It never carries foreign error strings,
hosts or user input, so it can be shown to the user in Release builds.

### 5. A 4-second deadline per host

Applies to: `CertFingerprintProbe.probeTimeout`

Unroutable hosts fail fast. A multi-host QR payload probes hosts in sequence,
so a hung host would otherwise stall the pairing spinner for minutes. 4 s
matches the WebSocket connect timeout that `ConnectionManager.raceHosts` uses
per host.

### 6. Probe setup stays off the main actor

Applies to: `CertFingerprintProbe.probe(host:port:timeout:)`, `.probeFirst(...)`,
`.probeViaTunnel(...)`, `.makeProbeConnection(...)`

The verify block and `stateUpdateHandler` are explicitly `@Sendable`, because
Network invokes them on the probe's private queue. An inherited `MainActor`
assertion would trap there (`EXC_BREAKPOINT` in `dispatch_assert_queue_fail`).
`fingerprint(fromServerTrust:)` and `endpointPort(_:)` are pure so they can be
unit-tested; the verify block is only the Network wiring around them.

### 7. Multi-host probing returns the first fingerprint or the last failure

Applies to: `CertFingerprintProbe.probeFirst(hosts:port:diagnostics:probe:)`

Hosts are probed in order. The first fingerprint wins. When no host yields one,
the result of the last host is returned, so the stage and cause of the failure
survive. The probe function is injectable for tests.

### 8. Tunnel probing stays pinned and closes on every path

Applies to: `CertFingerprintProbe.probeViaTunnel(dialer:tcAddress:remotePort:probe:)`

For manual tc-address entry, the probe opens a Tailcat tunnel, probes its
loopback forwarder, and closes the tunnel. Pairing over the tunnel stays pinned
exactly like direct hosts. An out-of-range `remotePort` returns `.invalidPort`
before any tunnel is dialed, as on the direct path. The function throws when
the tunnel cannot be dialed (invalid or unreachable tc address). A result other
than a fingerprint means the tunnel came up but the probe through it failed at
the named stage.

The injected probe must stay non-throwing. Closing on every path relies on the
linear open → probe → close flow, because `defer { await close() }` cannot be
written. A throwing probe would leak the tunnel.
