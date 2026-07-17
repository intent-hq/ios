Addresses the meta-critique from PRs #10/#11/#12/#14: the existing `*LiveStateTests` suites exercise the reconciler + parser via `handleStreamEvent` injection, but do NOT cover the subscribe lifecycle itself.

## Changes

### Test seam (production):
- **ConnectionManagerProtocol.swift**: Minimal protocol extracting the subset of ConnectionManager API that stores use (request, onEvent, removeEventHandler, connectionStatePublisher). Keeps seam narrow and well-documented.
- **Store updates**: NoteStore, TaskStore, CommentStore, ConversationStore now accept `connectionManager: ConnectionManagerProtocol = ConnectionManager.shared` via init. Default behavior unchanged.

### Test infrastructure:
- **FakeConnectionManager.swift**: Test double that lets tests drive the subscribe flow:
  - Control connection state transitions
  - Inject RPC responses (subscribe/unsubscribe)  
  - Inject events (subscription.push)
  - Verify method calls and parameters

### Store-level integration tests (NEW):
Each store now has a corresponding `*IntegrationTests.swift` file covering:

1. **Subscribe on connect**: connect → store issues `<channel>.subscribe` → fake returns subscriptionId + initial snapshot → store's observable state matches the snapshot, `<channel>Live` flag is true
2. **Contiguous delta**: after subscribe, deliver a delta with contiguous seq → state advances correctly
3. **Gap-triggered resnapshot**: deliver a delta with a gap → store unsubscribes, resubscribes, AND performs the baseline refetch (verify the refetch method was called)
4. **Connection loss + reconnect**: simulate disconnect → `<channel>Live` becomes false, reconciler cleared. Reconnect → fresh subscribe + snapshot → state consistent
5. **Legacy event suppressed while live**: with `<channel>Live == true`, inject the legacy per-channel event (e.g. `note.updated`) → store does NOT double-apply / refetch
6. **Wrong-subscriptionId push dropped**: with an active subscription id X, inject a push carrying subscriptionId Y → store's state unchanged

Test files:
- **NoteStoreIntegrationTests.swift**: 6 tests (full matrix)
- **TaskStoreIntegrationTests.swift**: 6 tests (full matrix)
- **CommentStoreIntegrationTests.swift**: 5 tests
- **ConversationStoreIntegrationTests.swift**: 4 tests

## Constraints
- ✅ No production logic changes beyond the seam
- ✅ All existing tests pass unchanged
- ✅ Existing `*LiveStateTests` suites remain untouched (complement, not replace)

## Testing
Verified locally with `xcodebuild test` on the IntentTests target.

## Related
Complements the router refactor in the parallel PR (refactor/ios-subscription-push-router). This PR is independent and can merge in either order.
