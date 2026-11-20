# ADR-1308: Call page JavaScript through the Objective-C WebKit method

- Status: Accepted
- Recorded: 2026-11-20 (moved from code comments; the decisions are older)
- Applies to: `WKWebView.callJavaScript(_:arguments:in:)` (`Intent/Utils/WKWebView+PageJavaScript.swift`)
- Related issues: ios#905

## Context

`callJavaScript` runs a function body as an async JavaScript function in the main
frame of a content world and returns its result.

## Decisions

### 1. Never use WebKit's Swift `callAsyncJavaScript`

Applies to: `WKWebView.callJavaScript(_:arguments:in:)`

Use `callJavaScript`, never WebKit's Swift
`callAsyncJavaScript(_:arguments:in:contentWorld:)`. With the iOS 18.0
deployment target, that method binds to `/usr/lib/swift/libswiftWebKit.dylib`,
and the iOS 18.4–18.5 simulator runtimes cannot load it, so the app aborts before
`main` (ios#905, WebKit bug 293831). `callJavaScript` calls the Objective-C
method, which lives in WebKit.framework on every supported iOS version.

## Consequences

`scripts/check-webkit-overlay-linkage.sh` fails the build lane if the overlay
comes back.
