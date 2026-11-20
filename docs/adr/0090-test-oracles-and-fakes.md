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
   4. Timeout tests poll the production timeout with a bounded wait ([ADR 0077](0077-test-synchronization-and-fakes.md)). A negative check watches past the timeout, so a stale timeout fails the moment it clears the overlay.
   5. To assert a transient "reconnecting" state, the recovery fixture server parks admission replies (`client.hello`, `principal.me`) with `holdHandshakes()`. No replacement can be adopted until `releaseHandshakes()`, however fast it dials, so the assertion cannot race a fast recovery (ios#261, `awaitParkedReplacement(on:timeout:sourceLocation:after:)`).
   6. The loopback pairing server retains every accepted `NWConnection` for its lifetime. An unreferenced `NWConnection` deallocates and drops the socket.

5. **Conversation startup RPC budgets.**
   1. Budget tests count every frame at the connection boundary (`RPCTraffic`), including deferred completions and cleanup, and assert exact byte totals. A request change that adds bytes (for example an explicit `limit`) must update the total on purpose.
   2. A scripted daemon rejection (`RPCFixtureRejection`) carries a JSON error and stays in the ledger. A local cancellation or error has no JSON response and adds no bytes.
   3. `ConversationBudgetEvidence.emit(_:_:)` writes the same test body's traffic as an artifact only when `STARTUP_BUDGET_DIRECTORY` is set. It is connection-boundary JSON, not a socket capture or a first-paint measurement.
   4. `ConversationBudgetFixture` uses valid persisted wire rows shared with the desktop source replay. Lifecycle fixtures keep their own registration ids.
   5. A test that counts requests releases every recorded request before the count, so a duplicate read fails the count instead of leaving a fake continuation orphaned.
   6. `ConversationStartupFixture` uses the real backend session composition across real view models; a second panel shares the conversation, detail and workspace status owners, and the recorder counts every request they make, including window and row leases. The view's separate model-catalog task belongs to the opening total.
   7. A frame the daemon already sent can arrive after close. It costs bytes even though its orphaned registration has no local consumer.
   8. Media budget tests use the real session media caches and a fixed, valid PNG, so the count does not depend on an OS encoder. A portable harness that stubs these caches must not report the test as run.
   9. Traces matched with the desktop use the daemon's canonical `tool_result` field, so the desktop's strict decoder reads the same content. Older iOS-only fixtures may still use aliases. `ConversationStreamingFixture` holds matched traces only, with no reducer: tests feed its frames through `SubscriptionPush` and the store. Its text uses UTF-8 beyond ASCII to catch character and byte confusion.
   10. The request recorder's sent ledger is a wire record. A caller's local cancellation is not a server reply and leaves the request in the ledger; only a timeout, a terminal transport boundary, removes it. A wire operation can outlive its cancelled final interest, and a replacement generation is also counted.
   11. Image budget fixtures separate the limits: a scale-3 rectangular image catches point and pixel confusion, a 2048-pixel square meets the edge cap but not the byte cap, and high-entropy pixels test byte limits apart from dimension limits.
6. **Design expectations** in rendered design tests are independent values from the design (for example the question card shell and 10% outline, #756), checked on the composited result including opacity, not values read back from the code under test.

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
- `RPCTraffic`, `RPCFixtureRejection`, `ConversationBudgetEvidence`, `ConversationBudgetFixture`; `ConversationCatalogLifecycleTests`, `ConversationDesignTests`
- `TestKeychainStorage`, `BackgroundPresentationClock`, `ConnectionManagerTests.awaitParkedReplacement(on:timeout:sourceLocation:after:)`; `AppCoordinatorTests`, `AppCoordinatorAutoOpenTests`, `AppCoordinatorBackgroundRecoveryTests`
- `AttachmentImageLoaderTests`, `AgentStoreTests`, `AgentStoreScopedLifecycleTests`, `BackendSessionRegistryTests`
