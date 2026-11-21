# Architecture decision records

These records hold the non-obvious decisions behind the app code in `Intent/`.
They were moved out of code comments. The code does not point back to them, so
each record names the types and files it applies to.

## Numbering

Records are numbered in one sequence and grouped by area in the [index](#index). Numbers are not reused. The records were renumbered on 2026-11-21; [renumbering.md](renumbering.md) maps the old numbers that issues and pull requests cite.

## Format

File name: `NNNN-short-kebab-title.md`. One record covers one topic: a type, a
family of types, or one feature flow.

```markdown
# ADR-NNNN: Title

- Status: Accepted
- Recorded: YYYY-MM-DD (moved from code comments; the decisions are older)
- Applies to: `Type` (`Intent/Path/File.swift`), …
- Related issues: ios#123, … (omit the line when there are none)

## Context

What the code does and what problem made a decision necessary.

## Decisions

### 1. Short statement of the decision

Applies to: `Type.member`

The decision, the reason, and what breaks if it is changed.

## Consequences

What callers and future changes must respect. Omit when the decisions say it all.
```

## Rules

1. Record only what the code cannot show: reasons, invariants, ordering
   constraints, protocol contracts, rejected alternatives, platform behavior.
2. Do not record a reason that is not known. Write what was decided and stop.
3. Name symbols and files. Do not use line numbers.
4. When a decision changes, edit its record in the same change, or add a new
   record and mark the old one `Superseded by ADR-NNNN`.

## Index

### Comment policy

| ADR | Title |
| --- | --- |
| [0001](0001-no-code-comments.md) | No code comments; decisions live in ADRs |

### `Intent/App`, `Intent/ViewModels`

| ADR | Title |
| --- | --- |
| [0002](0002-backend-session-registry.md) | One shared, refcounted session per saved backend |
| [0003](0003-window-binding-and-retarget.md) | Window binding, retargeting, and backend removal |
| [0004](0004-window-scene-title-and-activation.md) | Window scene title and activation go through the window's own scene |
| [0005](0005-connection-loss-and-remote-phase.md) | Connection loss presentation and the remote phase |
| [0006](0006-pairing-switching-and-log-off.md) | Pairing, switching, and logging off a window's backend |
| [0007](0007-deep-links-and-invites.md) | Deep links and workspace invites need confirmation |
| [0008](0008-screen-navigation-and-restoration.md) | Screen navigation, last-screen restoration, and agent history |
| [0009](0009-root-view-navigation.md) | RootView navigation stacks and window-level presentation |
| [0010](0010-ipad-shell-navigation.md) | iPad shell layout and navigation |
| [0011](0011-conversation-view-model-lifecycle.md) | Conversation view model lifecycle, sending, and model catalog |
| [0012](0012-agent-qa-pending-questions.md) | Agent Q&A pending questions follow the daemon marker |
| [0013](0013-agent-list-ordering-and-tree.md) | Agent list parents, orphans, and ordering |
| [0014](0014-workspace-list-status-and-grouping.md) | Workspace list status, dots, and grouping |
| [0015](0015-diagnostic-export.md) | Diagnostic log export lifecycle |

### `Intent/Models`, persistence files in `Intent/`

| ADR | Title |
| --- | --- |
| [0016](0016-connection-registry-storage.md) | The connection registry keeps saved daemons in one Keychain blob and never treats a failed read as empty |
| [0017](0017-owner-backend-publication.md) | Owner backend publication saves the intent locally first and never revives a newer removal |
| [0018](0018-invited-session-persistence.md) | Invited sessions fold removals first and install only the credential just authenticated |
| [0019](0019-per-backend-ui-state-persistence.md) | Per-backend drafts and screens migrate legacy values to the backend that owned them |
| [0020](0020-agent-session-list-and-avatar-state.md) | Agent sessions follow daemon wire rules, list reads establish absence, and avatar state mirrors the web client |
| [0021](0021-conversation-message-and-content-block-decoding.md) | Conversation messages and content blocks decode through one lenient path with stable ids |
| [0022](0022-wake-and-agent-message-attribution.md) | Wake and agent-message attribution is metadata-first and never alters stored text |
| [0023](0023-transcript-system-notices.md) | Daemon-persisted transcript notices are classified by metadata and fall back to the generic banner |
| [0024](0024-github-repos-and-pull-requests.md) | GitHub repo and pull request models parse leniently and match the web client's PR rules |
| [0025](0025-agent-questions-wizard.md) | Agent questions are wizard-only, keyed by the daemon's pending marker, and answered with one tagged message |
| [0026](0026-new-messages-divider-placement.md) | The new-messages divider anchor is derived once per view model and never re-derived |
| [0027](0027-workspace-and-provider-wire-models.md) | Workspace and provider models follow the daemon wire contract and tolerate older daemons |
| [0028](0028-notes-tasks-and-comment-threads.md) | Notes, tasks, and comment threads keep slim and truncated reads distinct from full content |
| [0029](0029-scripts-monitors-hooks-and-terminals.md) | Script, monitor, hook, and terminal models keep server values and model only what the app shows |
| [0030](0030-workspace-changes-files-and-browser.md) | Workspace changes trust git for membership, and the workspace browser keeps the registry's address |
| [0031](0031-conversation-and-connection-tuning-constants.md) | Meaning of transcript follow and slow-frame tuning constants |

### `Intent/Presentation`

| ADR | Title |
| --- | --- |
| [0032](0032-screen-presentation-values.md) | Screen presentation values hold one modal plus independent side state |
| [0033](0033-markdown-preparation-and-caches.md) | Markdown preparation, bounded caches and link rows |
| [0034](0034-suggested-prompt-blocks.md) | Suggested prompt blocks follow the desktop parser |
| [0035](0035-tool-call-classification.md) | Tool call rows are classified by name and input, like the desktop |
| [0036](0036-creation-picker-selection.md) | Creation pickers keep valid selections across catalog reloads |
| [0037](0037-ipad-panes-and-focus.md) | iPad panes stay retained, and focus is scoped to the visible pane |
| [0038](0038-workspace-list-rows-and-sidebar.md) | Workspace list rows, auto-selection and the persistent sidebar |
| [0039](0039-edge-drawer-drag.md) | Edge drawer drags are computed in the drawer's opening frame |
| [0040](0040-launch-timeline-and-splash.md) | Launch timelines stop on cancellation, and splash animations are leased |
| [0041](0041-workspace-diff-syntax-and-rows.md) | Workspace diff highlighting and row layout |
| [0042](0042-conversation-loading-status.md) | Conversation loading status timing and steps |
| [0043](0043-transcript-row-state.md) | Transcript row disclosure and tool result pairing |
| [0044](0044-row-indicators-follow-desktop.md) | Note and workspace row indicators follow the desktop |
| [0045](0045-slash-skill-search.md) | Slash skill search lowercases the catalog once |
| [0046](0046-transcript-entry-scroll-and-viewport-anchor.md) | Transcript entry scroll and viewport anchor restoration |
| [0047](0047-transcript-recovery-lifecycle.md) | One reducer owns the transcript viewport across follows and end recovery |
| [0048](0048-transcript-follow-policy.md) | Transcript follow, pin and takeover rules |
| [0049](0049-transcript-geometry-repin-landing-recovery.md) | Transcript geometry, re-pins, follow landing and end recovery |
| [0050](0050-note-checkbox-segments.md) | Note checkbox lines are split out as native rows |

### `Intent/Services`: `Agent…` to `ConnectionTypes`

| ADR | Title |
| --- | --- |
| [0051](0051-coalesced-read-single-flight.md) | CoalescedRead runs one read at a time with at most one trailing pass |
| [0052](0052-agent-detail-and-summary-stores.md) | Agent detail and summary stores keep separate knowledge and ordered provenance |
| [0053](0053-agent-list-loading-and-events.md) | Agent list loading, scoped groups and event classification |
| [0054](0054-assistant-store.md) | AssistantStore observes lazily and keeps a shown failure through a read |
| [0055](0055-attachment-placement-and-loading.md) | Attachment placement and loading follow the daemon registry contract |
| [0056](0056-background-hook-store.md) | BackgroundHookStore leases the shared hook cache and folds hook events |
| [0057](0057-browser-tunnel.md) | The browser tunnel forwards only daemon-loopback traffic over its own wire format |
| [0058](0058-cert-fingerprint-probe.md) | Pairing probes the TLS certificate fingerprint with Network.framework |
| [0059](0059-comment-store-live-subscription.md) | CommentStore follows a live `comment.subscribe` feed |
| [0060](0060-connection-identity-and-admission.md) | Connection authority comes only from the admitted socket |
| [0061](0061-connection-routing-and-transport-seams.md) | Connection routing, event classification and transport seams |
| [0062](0062-host-racing-and-route-refresh.md) | Host racing settles on the first winner, and route refresh only adds hosts |
| [0063](0063-connection-manager-lifecycle.md) | ConnectionManager lifecycle, requests, recovery and startup |

### `Intent/Services`: `Conversation…` to `InvitedSyncKey`

| ADR | Title |
| --- | --- |
| [0064](0064-composer-attachment-pipeline.md) | Composer attachment pipeline: imports, limits, and send-time encoding |
| [0065](0065-conversation-commands-queue-and-markers.md) | Conversation commands: queue reconciliation and agent markers |
| [0066](0066-live-transcript-subscription-registration.md) | Live transcript subscription: registration, snapshot wait, and recovery |
| [0067](0067-live-transcript-state-snapshots-and-history.md) | Live transcript state: generations, snapshots, deltas, history, and hydration |
| [0068](0068-conversation-store-binding-and-bootstrap.md) | Conversation store: binding, bootstrap, events, and metadata reads |
| [0069](0069-conversation-send-attempt-reconciliation.md) | Conversation send attempts: identity, failure status, and reconciliation |
| [0070](0070-creation-catalogs-and-options-store.md) | Creation catalogs and the creation options store |
| [0071](0071-conversation-watched-agents.md) | Conversation watched agents: visibility and detail authority |
| [0072](0072-daemon-startup-status-and-file-highlighting.md) | Daemon startup status scope and file highlight decoding |
| [0073](0073-subscription-push-and-delta-reconciler.md) | Subscription push parsing and the delta reconciler |
| [0074](0074-github-repo-store-cache-and-branches.md) | GitHub repo store: session cache, single-page reads, and branch listings |
| [0075](0075-invite-join-guest-flow.md) | Joining by invite: the guest connection, identity proof, and join flow |
| [0076](0076-invited-session-registry-and-sync-keys.md) | Invited session registry, legacy migration receipts, and sync keys |

### `Intent/Services`: `InvitedSyncMerge` to `TransportDiagnosticFailure`

| ADR | Title |
| --- | --- |
| [0077](0077-invited-sync-journal-and-records.md) | Invited sync records keep raw fields, and the journal is token-free |
| [0078](0078-live-subscription-state.md) | LiveSubscription is one enum for a store's live subscription state |
| [0079](0079-load-phase.md) | LoadPhase keeps the last success on screen through failed refreshes |
| [0080](0080-media-audio-session-leases.md) | MediaAudioSession owns the process-wide audio session through leases |
| [0081](0081-mobile-terminal.md) | Mobile terminal store and connection |
| [0082](0082-monitored-pr-store-and-event-fold.md) | MonitoredPrStore shares the workspace monitor cache and folds prMonitor events |
| [0083](0083-network-availability-and-path-snapshot.md) | Network availability is presentation-only path evidence |
| [0084](0084-outgoing-inline-image-size-check.md) | Inline image requests are size-checked as a full RPC envelope |
| [0085](0085-note-store-reads-and-live-state.md) | NoteStore reads, slim rows, live state, and task status writes |
| [0086](0086-paged-reads.md) | Paged daemon reads, whole-note reads, and snapshot continuation |
| [0087](0087-pairing-flow-pinned-wss.md) | Pairing always connects pinned over wss |
| [0088](0088-permessage-deflate.md) | permessage-deflate (RFC 7692) codec |
| [0089](0089-pull-request-list-and-detail-stores.md) | Pull request list and detail stores |
| [0090](0090-proposal-action-store-loading.md) | Proposal action cards reuse settled agent detail |
| [0091](0091-recent-retention.md) | RecentRetention keeps recently viewed content for read-only mode |
| [0092](0092-remote-image-loader.md) | RemoteImageLoader caches remote markdown images per URL |
| [0093](0093-skill-catalog-store.md) | SkillCatalogStore caches successful catalogs per session |
| [0094](0094-speech-dictation.md) | visionOS live dictation with segment-aware merging |
| [0095](0095-synced-backend-registry-merge-and-publish.md) | iCloud-synced backend registry: read, merge, and publish |
| [0096](0096-tailcat-tunnel-dialing.md) | Tailcat tunnel dialing and teardown |
| [0097](0097-transport-diagnostic-failure.md) | Transport diagnostic failures are closed classifications |
| [0098](0098-task-store-live-state-and-event-classification.md) | TaskStore live state and task event classification |

### `Intent/Services`: `WebSocket…` to `WorkspaceVideo`

| ADR | Title |
| --- | --- |
| [0099](0099-websocket-transport-and-certificate-pinning.md) | WebSocket transport runs on Network.framework with certificate pinning |
| [0100](0100-websocket-handshake-framing-and-assembly.md) | WebSocket handshake, framing, and message assembly follow RFC 6455 and RFC 7692 |
| [0101](0101-websocket-admission-handshake.md) | Admission runs on a bootstrap socket and a startup wait always reconnects |
| [0102](0102-workspace-authority-gate-and-status-waiters.md) | Parked callers resume individually and never cancel the shared operation |
| [0103](0103-workspace-status-store-feeds.md) | Workspace status feeds are shared per backend with bounded journals |
| [0104](0104-workspace-store-list-and-live-subscription.md) | WorkspaceStore publishes only whole lists and patches the live reconciler |
| [0105](0105-workspace-changes-files-browser-and-diff-stores.md) | Workspace changes, files, browser, and diff stores keep shown data through failures |
| [0106](0106-workspace-file-media-loading-and-caching.md) | Workspace file media loads in bounded chunks and is cached per session |
| [0107](0107-workspace-creation-media-and-provider-options.md) | Workspace creation validates media up front and sends the first message safely |
| [0108](0108-workspace-scripts-store-and-discovery.md) | Workspace script starts settle before stop or remove |
| [0109](0109-workspace-invite-links.md) | Workspace invite links are capabilities pinned to GitHub accounts |
| [0110](0110-workspace-transfer-relay.md) | Workspace transfer never cancels a mutating RPC |

### `Intent/Views/Conversation`: top level, `Composer`, `Content`, `Notices`

| ADR | Title |
| --- | --- |
| [0111](0111-composer-text-view-return-and-sync.md) | The composer text view decides Return per platform and syncs SwiftUI state after each update pass |
| [0112](0112-visionos-floating-composer-and-coverage.md) | visionOS hosts one floating composer per window, hidden by covering layers |
| [0113](0113-message-input-send-focus-and-dictation.md) | MessageInputView owns send, focus and visionOS dictation rules |
| [0114](0114-workspace-composer-design-and-skill-picker.md) | The workspace composer design is presentation only; the skill picker memoizes its ranking |
| [0115](0115-assistant-views-and-connection-status.md) | Assistant views and the connection status block |
| [0116](0116-content-blocks-images-and-hydration.md) | Content blocks re-render only on their own changes and hydrate slim media on demand |
| [0117](0117-markdown-text-and-attachment-loader.md) | Markdown text routes media through the daemon and the window's session |
| [0118](0118-compact-markdown-style-and-links.md) | Compact markdown style, link presentation and unopenable links |
| [0119](0119-html-report-sandbox.md) | HTML reports render as inert, isolated documents with a bounded resource budget |
| [0120](0120-media-lightboxes-and-image-actions.md) | Media lightboxes and shared image actions |
| [0121](0121-workspace-text-file-viewer.md) | The workspace text file viewer uses TextKit 2 with fixed-height lines |
| [0122](0122-transcript-notice-cards.md) | Transcript notice and wake cards |
| [0123](0123-row-content-prepared-on-main-actor.md) | Row content is prepared on the main actor before row providers run |

### `Intent/Views/Conversation`: `Questions`, `StatusStrip`, `Transcript`

| ADR | Title |
| --- | --- |
| [0124](0124-question-wizard-answers-and-attachments.md) | Question wizard answers, drafts, and attachments |
| [0125](0125-workspace-question-panel-layout.md) | Workspace question panel layout and transitions |
| [0126](0126-background-hooks-and-monitored-pr-rows.md) | Background hook and monitored PR status rows |
| [0127](0127-script-watches-and-workspace-status-pills.md) | Script watches and workspace status pills |
| [0128](0128-transcript-message-rows.md) | Transcript message rows |
| [0129](0129-workspace-conversation-header.md) | Workspace conversation header |
| [0130](0130-transcript-copy-context-menu-overlay.md) | Transcript copy context menu overlay |
| [0131](0131-transcript-scroll-view-wiring.md) | Transcript scroll view wiring |
| [0132](0132-transcript-entry-scroll-and-retained-viewport.md) | Transcript entry scroll and retained viewport |
| [0133](0133-transcript-follow-to-bottom.md) | Transcript follow to bottom |
| [0134](0134-transcript-geometry-re-pinning.md) | Transcript geometry edges and re-pinning |
| [0135](0135-transcript-rows-end-marker-and-recovery.md) | Transcript rows, end marker, and unrealized-end recovery |
| [0136](0136-transcript-demo-instrumentation.md) | Transcript demo instrumentation |
| [0137](0137-conversation-column-composer-and-question-presentation.md) | Conversation column composer, question presentation, and status rows |

### `Intent/Views/Workspaces`: `AgentModelFields` to `WorkspaceChangesView`

| ADR | Title |
| --- | --- |
| [0138](0138-create-workspace-options-and-branch-loading.md) | Create Workspace reads options and branches from session stores and gates Create on settled loads |
| [0139](0139-add-agent-specialist-picker.md) | The add-agent specialist picker shares the session options cache |
| [0140](0140-github-repo-picker.md) | The GitHub repo picker merges recents, own repos and debounced search |
| [0141](0141-create-workspace-form-style-and-section-header.md) | Create Workspace form styling and the collapsible section header |
| [0142](0142-pull-request-list-detail-and-link-routing.md) | Pull request list, detail page and link routing |
| [0143](0143-workspace-action-launcher-and-menu.md) | The Intent menu launcher, its overlay and its visionOS depth |
| [0144](0144-workspace-attention-cue.md) | Workspace attention cue on visionOS |
| [0145](0145-workspace-browser-page-load-phase.md) | Workspace browser page load phase and cross-origin subframes |
| [0146](0146-workspace-page-lazy-rows.md) | Workspace page rows stay flat and do not reread stores |
| [0147](0147-share-workspace-sheet.md) | The Share Workspace sheet only creates invite links |
| [0148](0148-terminal-emulator-presented-callback.md) | The terminal reports presentation from `viewDidAppear` |

### `Intent/Views/Workspaces`: `WorkspaceCommitDetailsView` to `WorkspaceTransferSheet`

| ADR | Title |
| --- | --- |
| [0149](0149-workspace-detail-page-lifecycle-and-stores.md) | Workspace detail page keeps per-window stores and reloads on switch |
| [0150](0150-workspace-detail-presentations-and-actions.md) | Workspace page presentations, archive and delete, and resource actions |
| [0151](0151-workspace-detail-sidebar-and-placement.md) | Workspace page placement in the iPad shell sidebar and the Duo |
| [0152](0152-workspace-diff-views.md) | Workspace commit and file diff views measure and lay out rows |
| [0153](0153-workspace-file-tree-and-preview.md) | Workspace file tree guides and media preview failures |
| [0154](0154-workspace-list-sidebar-and-rows.md) | Workspace list sidebar styling, selection, and swipe highlights |
| [0155](0155-workspace-lazy-row-provider-snapshots.md) | Workspace lists snapshot row state before the lazy row provider |
| [0156](0156-workspace-status-image.md) | Workspace status image keying and loading |
| [0157](0157-connection-switcher.md) | Connection switcher action, drawer gestures, and new windows |
| [0158](0158-workspace-title-and-prompt-input.md) | Workspace title editing and the creation prompt text view |

### `Intent/Views`: `Agents`, `Components`, `Connection`, `Notes`, `Onboarding`, `Settings`

| ADR | Title |
| --- | --- |
| [0159](0159-agent-avatar-tile-and-pulse.md) | Agent avatar tile, colors, and render-server pulse |
| [0160](0160-agent-history-drawer.md) | Agent history drawer |
| [0161](0161-sendable-foreach-snapshots.md) | Deferred row lists use Sendable snapshots |
| [0162](0162-agent-row-attention-and-mute.md) | Agent row attention cues and notification mute |
| [0163](0163-edge-drawer.md) | Edge drawer layout, gestures, and accessibility |
| [0164](0164-toast-appearance.md) | Toast appearance and drag |
| [0165](0165-navigation-chrome-and-pane-swipe.md) | Navigation chrome, workspace subtitle, and pane swipe |
| [0166](0166-load-failure-view.md) | Load failure view |
| [0167](0167-repo-owner-avatar.md) | Repo owner avatar |
| [0168](0168-task-status-icon-and-progress-ring.md) | Task status icon and task progress ring match the desktop frontend |
| [0169](0169-window-feedback-sound.md) | Window feedback sound on visionOS |
| [0170](0170-assistant-launcher-layout.md) | Assistant launcher layout |
| [0171](0171-blocking-connection-loss-overlay.md) | Blocking connection-loss overlay |
| [0172](0172-read-only-banner-and-pill.md) | Read-only banner and pill clearance |
| [0173](0173-remote-read-only-controls.md) | Remote read-only controls and placeholders |
| [0174](0174-connection-sheet-and-saved-connection-cards.md) | Connection sheet and saved connection cards |
| [0175](0175-loading-and-connecting-screens.md) | Loading and connecting screens |
| [0176](0176-connection-pairing-and-connections-list.md) | Pairing finalization and the connections list |
| [0177](0177-connection-failure-auto-retry.md) | Connection failure screen and auto-retry |
| [0178](0178-note-detail-loading-and-refresh.md) | Note detail loading, refresh, and links |
| [0179](0179-note-content-task-rows-and-metadata.md) | Note content task rows, metadata header, and note list rows |
| [0180](0180-manual-pairing-entry.md) | Manual pairing entry and pairing screen layout |
| [0181](0181-qr-deep-link-and-invite-pairing.md) | QR, deep-link, and invite pairing |
| [0182](0182-splash-art-and-loading-indicator.md) | Splash art and loading indicator playback |
| [0183](0183-settings-presentation-and-diagnostic-export.md) | Settings presentation and diagnostic export |

### `Intent/Utils`, `Intent/DesignSystem`, `Intent/LiveActivity`

| ADR | Title |
| --- | --- |
| [0184](0184-diagnostic-event-schema-and-privacy.md) | Diagnostic events carry only closed values |
| [0185](0185-diagnostic-store-writer-and-export.md) | Diagnostic store, writer and report export |
| [0186](0186-app-logging-trace-and-launch-options.md) | App logging, conversation trace and launch options |
| [0187](0187-link-and-payload-parsing.md) | Link and pairing payload parsing |
| [0188](0188-notification-alert-routing-per-backend-window.md) | Agent alerts are scoped to their source backend and window |
| [0189](0189-notification-sound-and-chime.md) | Notification sound policy and the synthesized chime |
| [0190](0190-desktop-parity-formatting-and-parsing.md) | Formatting and parsing helpers that match the desktop app |
| [0191](0191-wkwebview-javascript-call-without-swift-overlay.md) | Call page JavaScript through the Objective-C WebKit method |
| [0192](0192-agent-avatar-design-catalog.md) | The agent avatar catalog matches the desktop bit for bit |
| [0193](0193-connection-sheet-and-palette-styling.md) | Connection sheet styling and the exact design palette |
| [0194](0194-conversation-design-constants.md) | Conversation design constants and the readable column |
| [0195](0195-layout-constants-and-ipad-shell.md) | Layout constants, visionOS targets and the iPad shell |
| [0196](0196-inter-typography.md) | Inter typography tokens |
| [0197](0197-button-styles-and-visionos-hover.md) | Button styles and visionOS gaze targets |
| [0198](0198-agent-live-activity.md) | The agent Live Activity |
| [0199](0199-push-relay-link-and-device-identity.md) | Push relay linking, device identity and request proofs |

### `Intent/Demo`

| ADR | Title |
| --- | --- |
| [0200](0200-demo-mode-debug-boundary.md) | Demo mode is a Debug-only seam with production-safe flags |
| [0201](0201-demo-connection-transport.md) | The demo transport feeds fixtures through the real connection path |
| [0202](0202-demo-connection-loss-scenarios.md) | Connection-loss scenarios drive the real publisher from trigger files |
| [0203](0203-demo-fixture-responses-and-gates.md) | Demo fixture responses mirror the daemon and wait on response gates |
| [0204](0204-demo-long-conversation-fixture.md) | The long conversation fixture exercises scrolling, delegation, and hydration |
| [0205](0205-demo-controlled-end-derealization.md) | Controlled end derealization is trigger-driven and restored on evidence |
| [0206](0206-demo-inline-media-fixtures.md) | Inline media fixtures are opt-in and self-contained |
| [0207](0207-demo-design-scenarios.md) | Design scenarios are data-only fixtures behind an in-memory daemon |
| [0208](0208-demo-workspace-tool-fixtures.md) | Workspace tool fixtures stay opt-in and test-friendly |
| [0209](0209-demo-failure-and-invite-seams.md) | Failure and invite seams reach error and sheet states without a host |
| [0210](0210-demo-ui-evidence-overlays.md) | UI evidence overlays are opt-in and passive |

### Tests, UI tests and tooling

These records use the older **Status / Context / Decision / Consequences / Code** layout.

| ADR | Title |
| --- | --- |
| [0211](0211-demo-fixtures-contract.md) | Demo fixtures are the UI test contract |
| [0212](0212-webkit-javascript-without-swift-overlay.md) | WebKit JavaScript calls avoid the Swift overlay |
| [0213](0213-bundle-and-build-contracts.md) | App bundle and build configuration contracts |
| [0214](0214-source-policy-tests.md) | Source policy tests |
| [0215](0215-test-oracles-and-fakes.md) | Test oracles, fixtures and fakes |
| [0216](0216-rendered-test-hosting.md) | Rendered unit-test hosting |
| [0217](0217-transcript-scroll-ui-tests.md) | Transcript scroll UI tests |
| [0218](0218-ui-tests-and-native-controls.md) | UI tests and native controls |
| [0219](0219-ui-test-fixtures-and-evidence.md) | UI test fixtures and evidence |
| [0220](0220-connection-loss-read-only.md) | Connection loss is read-only, not blocking |
| [0221](0221-subscription-push-routing.md) | Subscription push routing and buffering |
