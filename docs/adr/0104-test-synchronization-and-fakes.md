# 0104. Test synchronization and connection fakes

**Status:** Accepted (recorded 2026-11-20 from test comments)

## Context

Store tests spawn async work and race fakes against each other. Fixed `Task.sleep` delays made them slow and flaky (ios#261). A fake that drifts from `ConnectionManager` makes tests pass against behaviour that production does not have.

## Decision

1. **Bounded waits, not sleeps.** After spawning store work, a test waits with `waitUntil`, a bounded poll. On timeout it throws `ConditionWaitFailure` and names the call site, so a missed state transition aborts the test instead of letting it continue against a fake that never reached the state.
2. **Negative windows.** To assert that work was NOT spawned, use `expectNever`. It polls the forbidden condition for the whole window and fails the first time it holds. Positive assertions must use `waitUntil`.
3. **Gates order races.** To script the order of racing fakes, use `TestGate`. `wait()` suspends until `open()` and ignores cancellation, so a fake that must outlive its cancellation holds its lane until the test releases it.
4. **Escape hatch.** A time-limited race test wraps its body in `opening(onCancellationOf:)`. Cancelling the test task opens the gate, so a regression that awaits the gated fake fails the time limit instead of hanging the runner. Cancelling a candidate that waits on the gate does not open it.
5. **Losers wait for cancellation.** A raced loser that only waits to be cut short uses `suspendUntilCancelled()`, not a long sleep.
6. **Fakes mirror production.**
   1. A drop clears the live principal but remembers it, like `ConnectionManager`.
   2. With `failsCancelledRequests`, a request from an already-cancelled task throws `CancellationError` at once, like `ConnectionManager.awaitResponse`.
   3. `subscription.push` never goes through the legacy event handlers. It routes only to the handler registered for its subscription id.
   4. `stubChatSnapshot` stands in for the seq-0 snapshot that a live `chat.subscribe` owes after its ack. Every registration for the id receives it.

## Consequences

- A new fixed sleep in a store test needs a reason; prefer a gate or a bounded wait.
- Test oracles and other fake behaviour: see [0090](0090-test-oracles-and-fakes.md).
- Test servers listen on 127.0.0.1 only (`loopback(using:)`, ios#981). A listener on `.any` is dual-stack, and macOS then lets another process bind 127.0.0.1 on the same port with `SO_REUSEADDR` and answer the test's requests (for example with HTTP 401).
- A loopback test listener retains its accepted `NWConnection`s for its lifetime. An unreferenced connection can deallocate and cancel the handshake before the probe reads the certificate.
- Hosted accessibility lookups observe the run loop with a deadline until SwiftUI publishes the element; they never sleep.

## Code

- `FakeConnectionManager`: `stubChatSnapshot(subscriptionId:messages:meta:)`, `failsCancelledRequests`, `deliverEvent(method:params:)`, `deliverSubscriptionPush(_:)`
- `waitUntil`, `expectNever`, `ConditionWaitFailure`, `TestGate`, `suspendUntilCancelled()`
