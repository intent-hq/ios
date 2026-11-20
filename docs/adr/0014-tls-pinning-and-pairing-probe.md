# 0014. TLS pinning and the pairing certificate probe

**Status:** Accepted (recorded 2026-11-20 from code comments)

## Context

The app connects to daemons over WSS with a pinned certificate fingerprint. Manual token entry and some QR payloads carry no fingerprint, so the app must learn it before pairing.

## Decision

1. **Pairing is always pinned.** `CertFingerprintProbe` reads the server's leaf fingerprint before pairing. A missing fingerprint aborts pairing. There is no fallback to plain WS.
2. **Network.framework, not URLSession.** App Transport Security aborts the TLS handshake to non-local hosts (public IPs, Tailscale) before the server-trust delegate runs. The probe uses `NWConnection` like `WebSocketConnection`. A bare TLS handshake gives the certificate; no HTTP request is sent.
3. **Isolation.** Probe setup stays off the main actor. The verify block and `stateUpdateHandler` are `@Sendable`, because Network calls them on the probe's private queue. An inherited main-actor assertion traps there (`dispatch_assert_queue_fail`).
4. **Typed failures.** Every failure keeps its stage (`ProbeResult`), so callers can tell an unreachable host from a TLS problem. `classify(…)` rules:
   1. A captured fingerprint wins.
   2. A TLS-domain error means TCP connected and the handshake failed (`tlsFailed`).
   3. Any other error means `unreachable`.
   4. A handshake without a fingerprint means `noCertificate`. An empty fingerprint is the same case.
   5. No settlement before the deadline is `timeout`.
5. **Safe failure text.** `FailureCause` holds a static domain name, the numeric code and a static label for known codes. It never holds foreign error strings, hosts or user input, so Release builds can show it.
6. **Timeout and order.** `probeTimeout` is 4 s per host, the same as the per-host WebSocket timeout in `ConnectionManager` host racing. Multi-host QR payloads probe hosts in order, so a hung host must fail fast. `probeFirst(…)` returns the first fingerprint, else the last host's result, so the failure stage survives.
7. **Tailcat.** `probeViaTunnel(…)` opens the tunnel, probes its loopback forwarder and closes it, so tunnel pairing is pinned like direct hosts. An out-of-range port is rejected as `invalidPort` before dialing. The probe closure must not throw: close-on-all-paths depends on the linear open → probe → close flow, because an async `defer` cannot await `close()`.

## Consequences

- A daemon that presents no certificate cannot be paired.

## Code

- `CertFingerprintProbe`: `probe(…)`, `probeFirst(…)`, `probeViaTunnel(…)`, `classify(…)`, `makeProbeConnection(…)`, `probeTimeout`, `FailureCause`, `ProbeResult`, `outcome(forProbe:)`
