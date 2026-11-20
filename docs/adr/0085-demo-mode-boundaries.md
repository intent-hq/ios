# 0085. Demo mode boundaries and opt-in scenarios

**Status:** Accepted (recorded 2026-11-20 from code comments)

## Context

Demo mode (`--demo-data`) runs the app on fixture data with ephemeral storage and no pairing. UI tests, App Store screenshots and hands-on checks use it. Demo code must never reach a Release build, must test the real production paths, and must not change the screens that screenshots and older tests depend on. [ADR 0101](0101-demo-fixtures-contract.md) records the fixture wire contract; this record holds the boundaries around it.

## Decision

1. **Debug only.**
   1. Everything in `Intent/Demo/` compiles only in Debug. Release ignores demo flags.
   2. Demo entry points (fixtures, `connectDemo(serveFixtures:)`, launch probes) are Debug-only declarations, so a Release caller fails to compile.
   3. Outside `Intent/Demo/`, code reads `DemoMode` flags without a guard only to choose between production paths (ephemeral storage, skipped sync, routing), where Release's `false` is the production answer. A read that reaches demo code sits in that owner's single `#if DEBUG` seam.
   4. Launch arguments and environment are read once per process through `LaunchOptions`. App code does not query `ProcessInfo` for flags.
2. **Real production paths.**
   1. Fixtures act at the wire. `DemoConnectionTransport`, `DemoScriptMonitorFixtures` and `DemoDesignFixtures` return ordinary RPC payloads, chat snapshots and events into the normal handlers. They never set store or view state and never poll a server. `DemoDesignScenario` chooses data only; appearance, keyboard and layout come from the real screen.
   2. A subscription push is routed before its acknowledgement, the order a live daemon can produce; the router buffers it until the caller registers.
   3. Demo readiness follows the same connection transitions as the stores. `DemoStartupConnection` seeds a saved loopback route and then uses the production `ConnectionManager` and connecting and recovery views; only post-admission data comes from fixtures. A scripted drop clears the live principal until recovery, as in production.
   4. `DemoConnectionLoss` drives the real connection publisher, never the coordinator's overlay flag. A scenario runs once, also after Home or reselection. A background drop keeps reconnecting, like a real one. Root teardown cancels the scenario without reviving Home. `DemoNetworkPathMonitor` is file-gated and never changes real networking.
   5. `DemoSettings` writes only the ephemeral demo store. It hands out the seeded primary backend only on the first window appearance, so later foregrounding and new windows keep their own selection.
   6. `DemoFailureFixtures` fails each seam a fixed number of times per launch (first-read lists: per workspace), so Retry recovers. The workspace stores read a list on open and again on the live connection, so both reads fail and only Retry recovers.
3. **Opt-in scenarios.** Each extra scenario (history pages, inline images, PDF, text and HTML reports, startup transcript, browser scripts, failures) needs its own launch argument. Without it, the ordinary demo and the App Store screenshots stay unchanged. Every agent except the long-conversation agent keeps the 4-message transcript of screenshot 03.
4. **Evidence, not sleeps.**
   1. Tests synchronize on evidence, never on guessed sleeps. Gates use trigger files a test creates, because a fixed delay cannot account for a loaded simulator.
   2. `DemoConnectionLoss.record(_:)` writes persistent evidence, so a test sees even a one-frame presentation that XCUITest misses while `activate()` waits to settle. The quick recovery spans rendering frames but stays within the production grace period.
   3. History fixtures stamp transcript times from a process-stable anchor, so rebuilt snapshots keep message identity.
   4. Geometry probes such as `DemoIPadPaneGeometry` put only a one-point marker in the accessibility tree, because a pane-sized element changes XCTest hit testing of the controls under test. Probes are passive: no forced layout, responder change or visibility write.

## Consequences

- A new demo scenario adds a launch argument; it never changes the default fixtures.
- A store or view behaviour can be tested in demo mode only if it is reachable from the wire.

## Code

- `DemoMode`, `LaunchOptions`
- `DemoConnectionTransport`: `make(serveFixtures:arguments:)`; `connectDemo(serveFixtures:)`
- `DemoStartupConnection`, `DemoConnectionLoss`: `record(_:)`, `run(connection:coordinator:)`; `DemoNetworkPathMonitor`
- `DemoScriptMonitorFixtures`, `DemoDesignFixtures`, `DemoDesignScenario`
- `DemoSettings`: `consumeStartupBackendID()`
- `DemoFailureFixtures`: `response(for:params:)`
- `DemoIPadPaneGeometry`
