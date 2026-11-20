# 0090. Test oracles, fixtures and fakes

**Status:** Accepted (recorded 2026-11-20 from test comments)

## Context

Many unit tests check that the app matches another implementation: the desktop app (cloudlands-fe), the daemon protocol, or a published standard. The expected values in those tests are not arbitrary. If someone "fixes" them to match the Swift code, the test stops guarding parity. Some fakes also have a deliberate behaviour that the tests depend on.

## Decision

1. **Expected values come from the reference implementation.**
   1. Parity fixtures are computed with the desktop JavaScript, not with the Swift code under test. Example: the fallback avatar design for an agent id comes from `stringToSeededRandom(agentId).pick(fallbackAgentAvatarDesigns)` in cloudlands-fe `hash.ts` and `avatar-design.ts`. The fixtures cover all six fallback designs.
   2. The fixtures include seeds where the JavaScript float64 LCG step loses low bits and picks another design than exact integer math. The Swift step uses `Double` on purpose to match.
   3. Wire tests use literal byte vectors, ports and encoded URLs from the protocol (for example PROTOCOL §1.4 for browser tunnel frames). Do not replace them with values computed by the code under test.
   4. Hash tests use published vectors (NIST FIPS 180-2 `"abc"` for SHA-256).
2. **Contract fixtures are exact.** `BackendKeychainFixtures` is an offline, exact-byte copy of the monorepo backend-keychain contract. CI also compares it with the canonical Git revision. `BackendKeychainConformanceSupport` projects the real production values; it does not normalize routes or identities.
3. **Fakes.**
   1. `FakeConnectionManager` hops asynchronously when a caller is cancelled. A test that cancels a task and then resolves its pending request on the same main-actor turn covers "the real payload arrives inside a cancelled task".
   2. A fake that holds a response even when its caller is cancelled tests a store's own freshness guards, apart from transport cancellation.
   3. `MemorySyncedKeychain` stores only the JSON bytes given to Security. It never holds real credentials.
   4. Each test that touches persistence uses a private `UserDefaults` suite and an in-memory keychain, so no state leaks between tests or into the app container.
4. **Concurrency proofs.**
   1. To prove that a second call joins an in-flight one, the second task sets a main-actor mark as its first statement. Same-actor calls do not suspend before the join's `await`, so the mark proves the join happened before the first read resolves.
   2. Before the final count, a test resolves every suspended request and answers later ones at once. A regression then fails the count; it does not hang the suite.

## Consequences

- When the desktop changes its algorithm, update the fixtures from the desktop code, not from the Swift output.
- Timing-based positioning inside a debounce window is a known weakness (intent-hq/ios#1059).

## Code

- `AgentAvatarDesign`: `fallbackDesign(agentId:)`; `AgentAvatarDesignTests`
- `BrowserTunnelFrame`; `BrowserTunnelFrameTests`, `BrowserTunnelRelayTests`, `BrowserTunnelURLTests`
- `AttachmentUploadService`; `AttachmentUploadServiceTests`
- `BackendKeychainFixtures`, `BackendKeychainConformanceSupport`, `MemorySyncedKeychain`
- `FakeConnectionManager`: `pendingMethods`, `resolvePending(_:with:)`
- `AttachmentImageLoaderTests`, `AgentStoreTests`, `AgentStoreScopedLifecycleTests`, `BackendSessionRegistryTests`
