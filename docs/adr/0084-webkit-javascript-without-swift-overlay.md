# 0084. WebKit JavaScript calls avoid the Swift overlay

**Status:** Accepted (recorded 2026-11-20 from code comments)

## Context

With the iOS 18.0 deployment target, WebKit's Swift `callAsyncJavaScript(_:arguments:in:contentWorld:)` binds to `/usr/lib/swift/libswiftWebKit.dylib`. The iOS 18.4–18.5 simulator runtimes cannot load that library, so the app aborts before `main` (ios#905, WebKit bug 293831).

## Decision

1. App code runs page JavaScript only through `WKWebView.callJavaScript(_:arguments:in:)` and `callPageJavaScript(_:arguments:)`. They call the Objective-C method, which lives in WebKit.framework on every supported iOS version.
2. `scripts/check-webkit-overlay-linkage.sh` fails the build lane if the app links the Swift overlay again.

## Consequences

- Raising the deployment target past the broken runtimes allows a return to the Swift API; remove the check script in the same change.
- A WebKit async JavaScript call may never resume, even after its task is cancelled. Callers and probes wait for the reply with a bound, never unbounded (from test comments).
- `evaluateJavaScript(_:completionHandler:)` always runs in the page world. App-owned inspection uses an isolated content world, while page scripts stay disabled (from test comments).

## Code

- `WKWebView`: `callJavaScript(_:arguments:in:)`, `callPageJavaScript(_:arguments:)`
- `scripts/check-webkit-overlay-linkage.sh`
