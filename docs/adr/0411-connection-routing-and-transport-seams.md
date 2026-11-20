# ADR-0411: Connection routing, event classification and transport seams

- Status: Accepted
- Recorded: 2026-11-20 (moved from code comments; the decisions are older)
- Applies to: `EventClassification`, `ConnectionManagerRouting`, `NSError` extension
  (`Intent/Services/ConnectionTypes.swift`),
  `ConnectionRequestTransport`, `ConnectionManager.makeInProcessTransport`
  (`Intent/Services/ConnectionRequestTransport.swift`),
  `ConnectionSubscriptionRouter` (`Intent/Services/ConnectionSubscriptionRouter.swift`),
  `DiagnosticConnectContext` (`Intent/Services/ConnectionDiagnostics.swift`)

## Context

Stores talk to the daemon through `ConnectionManager`. They receive bus events
and `subscription.push` notifications, and they must be testable without a
socket. Demo builds serve fixtures in process.

## Decisions

### 1. Every store classifies every bus event type explicitly

Applies to: `EventClassification`, each store's `classify(type:data:)`

`EventClassification` says how a store reacts to one bus event type, or to one
discriminating payload value of it. Each store exposes a pure
`classify(type:data:)` that returns nil for anything its tables do not name.
The coverage test `IntentTests/EventCatalogCoverageTests.swift` then proves
that every type intentd emits on the store's channels is a deliberate decision.

1. `ignore`: deliberately dropped, because no rendered field depends on it.
2. `patchInPlace`: apply the payload to the row in place, with no refetch.
3. `refetch`: refetch the store's list. This is the non-live fallback only.

### 2. Stores depend on a narrow routing protocol

Applies to: `ConnectionManagerRouting`

The protocol is the subset of `ConnectionManager` that subscribe-channel stores
use. It exists so tests can inject a fake. `ConnectionManager` conforms as is.

### 3. JSON-RPC error data codes

Applies to: `NSError.intentErrorDataCodeKey`, `NSError.isEntityNotFound`

`intentErrorDataCodeKey` is the `userInfo` key that carries the JSON-RPC
`error.data.code` discriminator (PROTOCOL §3.3). `isEntityNotFound` is true
only for a definitive entity-not-found error.

### 4. An in-process transport can stand in for the socket, in Debug only

Applies to: `ConnectionRequestTransport`, `ConnectionManager.makeInProcessTransport(serveFixtures:arguments:)`

When a connection holds a `ConnectionRequestTransport`,
`ConnectionManager.request` asks it for every response instead of writing
JSON-RPC to a socket. It also supplies the identity and capabilities that a
daemon handshake would provide. A nil `principal` defers to the handshake.
`stop()` is called when the connection replaces or drops the transport.

`makeInProcessTransport` is the single Debug seam that chooses an in-process
transport. Debug demo launches get the fixture transport. Release has no demo
types and always uses the socket.

### 5. Subscription pushes are routed on the main actor with bounded replay

Applies to: `ConnectionSubscriptionRouter`

The router is owned by `MainActor` and keeps bounded replay state for
`subscription.push`. `route(method:params:)` returns true for any
`subscription.push`, including malformed ones. `route(_:)` takes a push that is
already parsed, because the live pump parses off `MainActor`.

### 6. Diagnostic connect context is closed and explicit

Applies to: `DiagnosticConnectContext`

The context is a closed enum supplied by the caller. It is never inferred from
credentials or backend IDs. Entry points that do not set it stay `unknown`.
