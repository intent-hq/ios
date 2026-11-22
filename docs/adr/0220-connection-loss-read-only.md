# ADR-0220: Connection loss is read-only, not blocking

**Status:** Accepted (recorded 2026-11-20 from code comments)

## Context

A connection to the Mac can drop briefly (backgrounding, network change) or stop. The app must stay useful during a drop without sending changes it cannot deliver.

## Decision

1. An ordinary drop shows a non-blocking banner, never the blocking screen. Only a stopped reconnection blocks, and Home stays reachable.
2. Every screen stays readable under the banner. Items viewed before the drop reopen from memory with their content (R1.9).
3. A conversation or workspace tab never loaded before the drop shows a placeholder, not a spinner or an error. It loads by itself after recovery (R1.10).
4. Controls that change something on the Mac are off during the drop (R1.12). Local controls stay on (R1.13).
5. A change in network status updates the presented banner in place.
6. A sheet open during the drop stays usable under the banner.
7. A quick background recovery never shows the banner and keeps the draft.
8. On a fresh install the scene network monitor starts only after the notification prompt is dismissed.

## Code

- `ConnectionLossUITests`, `ConnectionLossReadOnlyUITests`, `ConnectionLossReadOnlyPresentationUITests`, `ConnectionLossContrastAssertions`
