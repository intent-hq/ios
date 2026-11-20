# 0108. Source policy tests

**Status:** Accepted (recorded 2026-11-20 from test comments)

## Context

Some repository rules cannot be left to SwiftLint alone, because a lint rule can be suppressed in the file it checks. Unit tests scan the Swift sources instead. The sources come from the copies packaged into the test bundle (`TestSourceInputs`), never from the checkout through `#filePath` (ios#320).

## Decision

1. **Independent of lint.** A policy test enforces its rule even when the matching SwiftLint rule is suppressed. `LayoutPolicyTests` bans `GeometryReader` and any suppression of `geometry_reader_usage`.
2. **Self-scan safe.** A policy test scans its own source too. Banned tokens in its fixtures and patterns are split (`"Geometry" + "Reader"`), so the test passes its own scan. Do not join them.

## Consequences

- A policy test that reads a token from a comment breaks when the comment is deleted; the token must live in code or a string.

## Code

- `LayoutPolicyTests`: `reader`, `suppression`
- `TestSourceInputs`
