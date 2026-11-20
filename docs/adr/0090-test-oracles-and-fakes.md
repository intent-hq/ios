# 0090. Test oracles, fixtures and fakes

**Status:** Accepted (recorded 2026-11-20 from test comments)

## Context

Many unit tests check that the app matches another implementation: the desktop app (cloudlands-fe), the daemon protocol, or a published standard. The expected values in those tests are not arbitrary. If someone "fixes" them to match the Swift code, the test stops guarding parity. Some fakes also have a deliberate behaviour that the tests depend on.

## Decision

1. **Expected values come from the reference implementation.**
   1. Parity fixtures are computed with the desktop JavaScript, not with the Swift code under test. Example: the fallback avatar designs come from `stringToSeededRandom(agentId).pick(fallbackAgentAvatarDesigns)` in cloudlands-fe `hash.ts` and `avatar-design.ts`, and cover all six designs.
   2. The avatar fixtures include seeds where the JavaScript float64 LCG step loses low bits ([ADR 0083](0083-desktop-parity-ports.md)), so a switch to exact integer math fails them.
   3. Wire tests use literal byte vectors, ports and encoded URLs from the protocol (for example PROTOCOL §1.4 for browser tunnel frames). Do not replace them with values computed by the code under test.
   4. Hash tests use published vectors (NIST FIPS 180-2 `"abc"` for SHA-256).
2. **Contract fixtures are exact.** `BackendKeychainFixtures` is an offline, exact-byte copy of the monorepo backend-keychain contract. CI also compares it with the canonical Git revision. `BackendKeychainConformanceSupport` projects the real production values; it does not normalize routes or identities.
3. **Fakes.**
   1. `FakeConnectionManager` hops asynchronously when a caller is cancelled. A test that cancels a task and then resolves its pending request on the same main-actor turn covers "the real payload arrives inside a cancelled task".
   2. A fake that holds a response even when its caller is cancelled tests a store's own freshness guards, apart from transport cancellation.
   3. `MemorySyncedKeychain` stores only the JSON bytes given to Security. It never holds real credentials.
   4. Each test that touches persistence uses a private `UserDefaults` suite and an in-memory keychain, so no state leaks between tests or into the app container (intent-hq/monorepo#2677). The suite removes its persistent domain in `deinit`. Globals that are not injected can still reach `PersistenceManager.shared`, so suites install `TestKeychainStorage.installed` and SecItem is never called in headless CI.
   5. A coordinator under test gets an empty fake synced registry. The default registry would read the host machine's real keychain.
   6. `BackgroundPresentationClock` resumes even cancelled sleeps. The tests exercise the production generation and cancellation guards, not a fake that drops stale callbacks.
4. **Concurrency proofs.**
   1. To prove that a second call joins an in-flight one, the second task sets a main-actor mark as its first statement. Same-actor calls do not suspend before the join's `await`, so the mark proves the join happened before the first read resolves.
   2. Before the final count, a test resolves every suspended request and answers later ones at once. A regression then fails the count; it does not hang the suite.
   3. The coordinator's connection sink delivers on the main queue, and main-actor tasks enqueue on the same serial queue. One round trip through the main queue (`awaitMainQueueTurn()`) therefore drains a delivery.
   4. Timeout tests poll the production timeout with a bounded wait ([ADR 0104](0104-test-synchronization-and-fakes.md)). A negative check watches past the timeout, so a stale timeout fails the moment it clears the overlay.
   5. To assert a transient "reconnecting" state, the recovery fixture server parks admission replies (`client.hello`, `principal.me`) with `holdHandshakes()`. No replacement can be adopted until `releaseHandshakes()`, however fast it dials, so the assertion cannot race a fast recovery (ios#261, `awaitParkedReplacement(on:timeout:sourceLocation:after:)`).
   6. The loopback pairing server retains every accepted `NWConnection` for its lifetime. An unreferenced `NWConnection` deallocates and drops the socket.

## Consequences

- When the desktop changes its algorithm, update the fixtures from the desktop code, not from the Swift output.
- Timing-based positioning inside a debounce window is a known weakness (intent-hq/ios#1059).
- Keychain fakes model SecItem identity as access group plus account. An unscoped query returns rows from every readable group instead of collapsing them (`InvitedGroupedMigrationTests`) (from test comments).
- `InvitedSessionFixtures` copies the exact base object from the desktop `invited-session-sync.test.ts` (from test comments).

## Code

- `AgentAvatarDesign`: `fallbackDesign(agentId:)`; `AgentAvatarDesignTests`
- `BrowserTunnelFrame`; `BrowserTunnelFrameTests`, `BrowserTunnelRelayTests`, `BrowserTunnelURLTests`
- `AttachmentUploadService`; `AttachmentUploadServiceTests`
- `BackendKeychainFixtures`, `BackendKeychainConformanceSupport`, `MemorySyncedKeychain`
- `FakeConnectionManager`: `pendingMethods`, `resolvePending(_:with:)`
- `TestKeychainStorage`, `BackgroundPresentationClock`, `ConnectionManagerTests.awaitParkedReplacement(on:timeout:sourceLocation:after:)`; `AppCoordinatorTests`, `AppCoordinatorAutoOpenTests`, `AppCoordinatorBackgroundRecoveryTests`
- `AttachmentImageLoaderTests`, `AgentStoreTests`, `AgentStoreScopedLifecycleTests`, `BackendSessionRegistryTests`
