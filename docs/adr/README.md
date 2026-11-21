# Architecture decision records

These records hold the non-obvious decisions behind the app code in `Intent/`.
They were moved out of code comments. The code does not point back to them, so
each record names the types and files it applies to.

## Numbering

The first two digits give the area. Numbers are not reused.

| Range | Area |
| --- | --- |
| 00xx | Comment ratchet, tests, UI tests and tooling (see [00xx records](#00xx-records)) |
| 01xx | `Intent/App`, `Intent/ViewModels` |
| 02xx | `Intent/Models`, persistence files in `Intent/` |
| 03xx | `Intent/Presentation` |
| 04xx | `Intent/Services`: `Agent…` to `ConnectionTypes` |
| 05xx | `Intent/Services`: `Conversation…` to `InvitedSyncKey` |
| 06xx | `Intent/Services`: `InvitedSyncMerge` to `TransportDiagnosticFailure` |
| 07xx | `Intent/Services`: `WebSocket…` to `WorkspaceVideo` |
| 08xx | `Intent/Views/Conversation`: top level, `Composer`, `Content`, `Notices` |
| 09xx | `Intent/Views/Conversation`: `Questions`, `StatusStrip`, `Transcript` |
| 10xx | `Intent/Views/Workspaces`: `AgentModelFields` to `WorkspaceChangesView` |
| 11xx | `Intent/Views/Workspaces`: `WorkspaceCommitDetailsView` to `WorkspaceTransferSheet` |
| 12xx | `Intent/Views`: `Agents`, `Components`, `Connection`, `Notes`, `Onboarding`, `Settings` |
| 13xx | `Intent/Utils`, `Intent/DesignSystem`, `Intent/LiveActivity` |
| 14xx | `Intent/Demo` |

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

| ADR | Title |
| --- | --- |
| [0101](0101-backend-session-registry.md) | One shared, refcounted session per saved backend |
| [0102](0102-window-binding-and-retarget.md) | Window binding, retargeting, and backend removal |
| [0103](0103-window-scene-title-and-activation.md) | Window scene title and activation go through the window's own scene |
| [0104](0104-connection-loss-and-remote-phase.md) | Connection loss presentation and the remote phase |
| [0105](0105-pairing-switching-and-log-off.md) | Pairing, switching, and logging off a window's backend |
| [0106](0106-deep-links-and-invites.md) | Deep links and workspace invites need confirmation |
| [0107](0107-screen-navigation-and-restoration.md) | Screen navigation, last-screen restoration, and agent history |
| [0108](0108-root-view-navigation.md) | RootView navigation stacks and window-level presentation |
| [0109](0109-ipad-shell-navigation.md) | iPad shell layout and navigation |
| [0110](0110-conversation-view-model-lifecycle.md) | Conversation view model lifecycle, sending, and model catalog |
| [0111](0111-agent-qa-pending-questions.md) | Agent Q&A pending questions follow the daemon marker |
| [0112](0112-agent-list-ordering-and-tree.md) | Agent list parents, orphans, and ordering |
| [0113](0113-workspace-list-status-and-grouping.md) | Workspace list status, dots, and grouping |
| [0114](0114-diagnostic-export.md) | Diagnostic log export lifecycle |
| [0201](0201-connection-registry-storage.md) | The connection registry keeps saved daemons in one Keychain blob and never treats a failed read as empty |
| [0202](0202-owner-backend-publication.md) | Owner backend publication saves the intent locally first and never revives a newer removal |
| [0203](0203-invited-session-persistence.md) | Invited sessions fold removals first and install only the credential just authenticated |
| [0204](0204-per-backend-ui-state-persistence.md) | Per-backend drafts and screens migrate legacy values to the backend that owned them |
| [0205](0205-agent-session-list-and-avatar-state.md) | Agent sessions follow daemon wire rules, list reads establish absence, and avatar state mirrors the web client |
| [0206](0206-conversation-message-and-content-block-decoding.md) | Conversation messages and content blocks decode through one lenient path with stable ids |
| [0207](0207-wake-and-agent-message-attribution.md) | Wake and agent-message attribution is metadata-first and never alters stored text |
| [0208](0208-transcript-system-notices.md) | Daemon-persisted transcript notices are classified by metadata and fall back to the generic banner |
| [0209](0209-github-repos-and-pull-requests.md) | GitHub repo and pull request models parse leniently and match the web client's PR rules |
| [0210](0210-agent-questions-wizard.md) | Agent questions are wizard-only, keyed by the daemon's pending marker, and answered with one tagged message |
| [0211](0211-new-messages-divider-placement.md) | The new-messages divider anchor is derived once per view model and never re-derived |
| [0212](0212-workspace-and-provider-wire-models.md) | Workspace and provider models follow the daemon wire contract and tolerate older daemons |
| [0213](0213-notes-tasks-and-comment-threads.md) | Notes, tasks, and comment threads keep slim and truncated reads distinct from full content |
| [0214](0214-scripts-monitors-hooks-and-terminals.md) | Script, monitor, hook, and terminal models keep server values and model only what the app shows |
| [0215](0215-workspace-changes-files-and-browser.md) | Workspace changes trust git for membership, and the workspace browser keeps the registry's address |
| [0216](0216-conversation-and-connection-tuning-constants.md) | Meaning of transcript follow and slow-frame tuning constants |
| [0301](0301-screen-presentation-values.md) | Screen presentation values hold one modal plus independent side state |
| [0302](0302-markdown-preparation-and-caches.md) | Markdown preparation, bounded caches and link rows |
| [0303](0303-suggested-prompt-blocks.md) | Suggested prompt blocks follow the desktop parser |
| [0304](0304-tool-call-classification.md) | Tool call rows are classified by name and input, like the desktop |
| [0305](0305-creation-picker-selection.md) | Creation pickers keep valid selections across catalog reloads |
| [0306](0306-ipad-panes-and-focus.md) | iPad panes stay retained, and focus is scoped to the visible pane |
| [0307](0307-workspace-list-rows-and-sidebar.md) | Workspace list rows, auto-selection and the persistent sidebar |
| [0308](0308-edge-drawer-drag.md) | Edge drawer drags are computed in the drawer's opening frame |
| [0309](0309-launch-timeline-and-splash.md) | Launch timelines stop on cancellation, and splash animations are leased |
| [0310](0310-workspace-diff-syntax-and-rows.md) | Workspace diff highlighting and row layout |
| [0311](0311-conversation-loading-status.md) | Conversation loading status timing and steps |
| [0312](0312-transcript-row-state.md) | Transcript row disclosure and tool result pairing |
| [0313](0313-row-indicators-follow-desktop.md) | Note and workspace row indicators follow the desktop |
| [0314](0314-slash-skill-search.md) | Slash skill search lowercases the catalog once |
| [0315](0315-transcript-entry-scroll-and-viewport-anchor.md) | Transcript entry scroll and viewport anchor restoration |
| [0316](0316-transcript-recovery-lifecycle.md) | One reducer owns the transcript viewport across follows and end recovery |
| [0317](0317-transcript-follow-policy.md) | Transcript follow, pin and takeover rules |
| [0318](0318-transcript-geometry-repin-landing-recovery.md) | Transcript geometry, re-pins, follow landing and end recovery |
| [0319](0319-note-checkbox-segments.md) | Note checkbox lines are split out as native rows |
| [0401](0401-coalesced-read-single-flight.md) | CoalescedRead runs one read at a time with at most one trailing pass |
| [0402](0402-agent-detail-and-summary-stores.md) | Agent detail and summary stores keep separate knowledge and ordered provenance |
| [0403](0403-agent-list-loading-and-events.md) | Agent list loading, scoped groups and event classification |
| [0404](0404-assistant-store.md) | AssistantStore observes lazily and keeps a shown failure through a read |
| [0405](0405-attachment-placement-and-loading.md) | Attachment placement and loading follow the daemon registry contract |
| [0406](0406-background-hook-store.md) | BackgroundHookStore leases the shared hook cache and folds hook events |
| [0407](0407-browser-tunnel.md) | The browser tunnel forwards only daemon-loopback traffic over its own wire format |
| [0408](0408-cert-fingerprint-probe.md) | Pairing probes the TLS certificate fingerprint with Network.framework |
| [0409](0409-comment-store-live-subscription.md) | CommentStore follows a live `comment.subscribe` feed |
| [0410](0410-connection-identity-and-admission.md) | Connection authority comes only from the admitted socket |
| [0411](0411-connection-routing-and-transport-seams.md) | Connection routing, event classification and transport seams |
| [0412](0412-host-racing-and-route-refresh.md) | Host racing settles on the first winner, and route refresh only adds hosts |
| [0413](0413-connection-manager-lifecycle.md) | ConnectionManager lifecycle, requests, recovery and startup |
| [0501](0501-composer-attachment-pipeline.md) | Composer attachment pipeline: imports, limits, and send-time encoding |
| [0502](0502-conversation-commands-queue-and-markers.md) | Conversation commands: queue reconciliation and agent markers |
| [0503](0503-live-transcript-subscription-registration.md) | Live transcript subscription: registration, snapshot wait, and recovery |
| [0504](0504-live-transcript-state-snapshots-and-history.md) | Live transcript state: generations, snapshots, deltas, history, and hydration |
| [0505](0505-conversation-store-binding-and-bootstrap.md) | Conversation store: binding, bootstrap, events, and metadata reads |
| [0506](0506-conversation-send-attempt-reconciliation.md) | Conversation send attempts: identity, failure status, and reconciliation |
| [0507](0507-creation-catalogs-and-options-store.md) | Creation catalogs and the creation options store |
| [0508](0508-conversation-watched-agents.md) | Conversation watched agents: visibility and detail authority |
| [0509](0509-daemon-startup-status-and-file-highlighting.md) | Daemon startup status scope and file highlight decoding |
| [0510](0510-subscription-push-and-delta-reconciler.md) | Subscription push parsing and the delta reconciler |
| [0511](0511-github-repo-store-cache-and-branches.md) | GitHub repo store: session cache, single-page reads, and branch listings |
| [0512](0512-invite-join-guest-flow.md) | Joining by invite: the guest connection, identity proof, and join flow |
| [0513](0513-invited-session-registry-and-sync-keys.md) | Invited session registry, legacy migration receipts, and sync keys |
| [0601](0601-invited-sync-journal-and-records.md) | Invited sync records keep raw fields, and the journal is token-free |
| [0602](0602-live-subscription-state.md) | LiveSubscription is one enum for a store's live subscription state |
| [0603](0603-load-phase.md) | LoadPhase keeps the last success on screen through failed refreshes |
| [0604](0604-media-audio-session-leases.md) | MediaAudioSession owns the process-wide audio session through leases |
| [0605](0605-mobile-terminal.md) | Mobile terminal store and connection |
| [0606](0606-monitored-pr-store-and-event-fold.md) | MonitoredPrStore shares the workspace monitor cache and folds prMonitor events |
| [0607](0607-network-availability-and-path-snapshot.md) | Network availability is presentation-only path evidence |
| [0608](0608-outgoing-inline-image-size-check.md) | Inline image requests are size-checked as a full RPC envelope |
| [0609](0609-note-store-reads-and-live-state.md) | NoteStore reads, slim rows, live state, and task status writes |
| [0610](0610-paged-reads.md) | Paged daemon reads, whole-note reads, and snapshot continuation |
| [0611](0611-pairing-flow-pinned-wss.md) | Pairing always connects pinned over wss |
| [0612](0612-permessage-deflate.md) | permessage-deflate (RFC 7692) codec |
| [0613](0613-pull-request-list-and-detail-stores.md) | Pull request list and detail stores |
| [0614](0614-proposal-action-store-loading.md) | Proposal action cards reuse settled agent detail |
| [0615](0615-recent-retention.md) | RecentRetention keeps recently viewed content for read-only mode |
| [0616](0616-remote-image-loader.md) | RemoteImageLoader caches remote markdown images per URL |
| [0617](0617-skill-catalog-store.md) | SkillCatalogStore caches successful catalogs per session |
| [0618](0618-speech-dictation.md) | visionOS live dictation with segment-aware merging |
| [0619](0619-synced-backend-registry-merge-and-publish.md) | iCloud-synced backend registry: read, merge, and publish |
| [0620](0620-tailcat-tunnel-dialing.md) | Tailcat tunnel dialing and teardown |
| [0621](0621-transport-diagnostic-failure.md) | Transport diagnostic failures are closed classifications |
| [0622](0622-task-store-live-state-and-event-classification.md) | TaskStore live state and task event classification |
| [0701](0701-websocket-transport-and-certificate-pinning.md) | WebSocket transport runs on Network.framework with certificate pinning |
| [0702](0702-websocket-handshake-framing-and-assembly.md) | WebSocket handshake, framing, and message assembly follow RFC 6455 and RFC 7692 |
| [0703](0703-websocket-admission-handshake.md) | Admission runs on a bootstrap socket and a startup wait always reconnects |
| [0704](0704-workspace-authority-gate-and-status-waiters.md) | Parked callers resume individually and never cancel the shared operation |
| [0705](0705-workspace-status-store-feeds.md) | Workspace status feeds are shared per backend with bounded journals |
| [0706](0706-workspace-store-list-and-live-subscription.md) | WorkspaceStore publishes only whole lists and patches the live reconciler |
| [0707](0707-workspace-changes-files-browser-and-diff-stores.md) | Workspace changes, files, browser, and diff stores keep shown data through failures |
| [0708](0708-workspace-file-media-loading-and-caching.md) | Workspace file media loads in bounded chunks and is cached per session |
| [0709](0709-workspace-creation-media-and-provider-options.md) | Workspace creation validates media up front and sends the first message safely |
| [0710](0710-workspace-scripts-store-and-discovery.md) | Workspace script starts settle before stop or remove |
| [0711](0711-workspace-invite-links.md) | Workspace invite links are capabilities pinned to GitHub accounts |
| [0712](0712-workspace-transfer-relay.md) | Workspace transfer never cancels a mutating RPC |
| [0801](0801-composer-text-view-return-and-sync.md) | The composer text view decides Return per platform and syncs SwiftUI state after each update pass |
| [0802](0802-visionos-floating-composer-and-coverage.md) | visionOS hosts one floating composer per window, hidden by covering layers |
| [0803](0803-message-input-send-focus-and-dictation.md) | MessageInputView owns send, focus and visionOS dictation rules |
| [0804](0804-workspace-composer-design-and-skill-picker.md) | The workspace composer design is presentation only; the skill picker memoizes its ranking |
| [0805](0805-assistant-views-and-connection-status.md) | Assistant views and the connection status block |
| [0806](0806-content-blocks-images-and-hydration.md) | Content blocks re-render only on their own changes and hydrate slim media on demand |
| [0807](0807-markdown-text-and-attachment-loader.md) | Markdown text routes media through the daemon and the window's session |
| [0808](0808-compact-markdown-style-and-links.md) | Compact markdown style, link presentation and unopenable links |
| [0809](0809-html-report-sandbox.md) | HTML reports render as inert, isolated documents with a bounded resource budget |
| [0810](0810-media-lightboxes-and-image-actions.md) | Media lightboxes and shared image actions |
| [0811](0811-workspace-text-file-viewer.md) | The workspace text file viewer uses TextKit 2 with fixed-height lines |
| [0812](0812-transcript-notice-cards.md) | Transcript notice and wake cards |
| [0813](0813-row-content-prepared-on-main-actor.md) | Row content is prepared on the main actor before row providers run |
| [0901](0901-question-wizard-answers-and-attachments.md) | Question wizard answers, drafts, and attachments |
| [0902](0902-workspace-question-panel-layout.md) | Workspace question panel layout and transitions |
| [0903](0903-background-hooks-and-monitored-pr-rows.md) | Background hook and monitored PR status rows |
| [0904](0904-script-watches-and-workspace-status-pills.md) | Script watches and workspace status pills |
| [0905](0905-transcript-message-rows.md) | Transcript message rows |
| [0906](0906-workspace-conversation-header.md) | Workspace conversation header |
| [0907](0907-transcript-copy-context-menu-overlay.md) | Transcript copy context menu overlay |
| [0908](0908-transcript-scroll-view-wiring.md) | Transcript scroll view wiring |
| [0909](0909-transcript-entry-scroll-and-retained-viewport.md) | Transcript entry scroll and retained viewport |
| [0910](0910-transcript-follow-to-bottom.md) | Transcript follow to bottom |
| [0911](0911-transcript-geometry-re-pinning.md) | Transcript geometry edges and re-pinning |
| [0912](0912-transcript-rows-end-marker-and-recovery.md) | Transcript rows, end marker, and unrealized-end recovery |
| [0913](0913-transcript-demo-instrumentation.md) | Transcript demo instrumentation |
| [0914](0914-conversation-column-composer-and-question-presentation.md) | Conversation column composer, question presentation, and status rows |
| [1001](1001-create-workspace-options-and-branch-loading.md) | Create Workspace reads options and branches from session stores and gates Create on settled loads |
| [1002](1002-add-agent-specialist-picker.md) | The add-agent specialist picker shares the session options cache |
| [1003](1003-github-repo-picker.md) | The GitHub repo picker merges recents, own repos and debounced search |
| [1004](1004-create-workspace-form-style-and-section-header.md) | Create Workspace form styling and the collapsible section header |
| [1005](1005-pull-request-list-detail-and-link-routing.md) | Pull request list, detail page and link routing |
| [1006](1006-workspace-action-launcher-and-menu.md) | The Intent menu launcher, its overlay and its visionOS depth |
| [1007](1007-workspace-attention-cue.md) | Workspace attention cue on visionOS |
| [1008](1008-workspace-browser-page-load-phase.md) | Workspace browser page load phase and cross-origin subframes |
| [1009](1009-workspace-page-lazy-rows.md) | Workspace page rows stay flat and do not reread stores |
| [1010](1010-share-workspace-sheet.md) | The Share Workspace sheet only creates invite links |
| [1011](1011-terminal-emulator-presented-callback.md) | The terminal reports presentation from `viewDidAppear` |
| [1101](1101-workspace-detail-page-lifecycle-and-stores.md) | Workspace detail page keeps per-window stores and reloads on switch |
| [1102](1102-workspace-detail-presentations-and-actions.md) | Workspace page presentations, archive and delete, and resource actions |
| [1103](1103-workspace-detail-sidebar-and-placement.md) | Workspace page placement in the iPad shell sidebar and the Duo |
| [1104](1104-workspace-diff-views.md) | Workspace commit and file diff views measure and lay out rows |
| [1105](1105-workspace-file-tree-and-preview.md) | Workspace file tree guides and media preview failures |
| [1106](1106-workspace-list-sidebar-and-rows.md) | Workspace list sidebar styling, selection, and swipe highlights |
| [1107](1107-workspace-lazy-row-provider-snapshots.md) | Workspace lists snapshot row state before the lazy row provider |
| [1108](1108-workspace-status-image.md) | Workspace status image keying and loading |
| [1109](1109-connection-switcher.md) | Connection switcher action, drawer gestures, and new windows |
| [1110](1110-workspace-title-and-prompt-input.md) | Workspace title editing and the creation prompt text view |
| [1201](1201-agent-avatar-tile-and-pulse.md) | Agent avatar tile, colors, and render-server pulse |
| [1202](1202-agent-history-drawer.md) | Agent history drawer |
| [1203](1203-sendable-foreach-snapshots.md) | Deferred row lists use Sendable snapshots |
| [1204](1204-agent-row-attention-and-mute.md) | Agent row attention cues and notification mute |
| [1205](1205-edge-drawer.md) | Edge drawer layout, gestures, and accessibility |
| [1206](1206-toast-appearance.md) | Toast appearance and drag |
| [1207](1207-navigation-chrome-and-pane-swipe.md) | Navigation chrome, workspace subtitle, and pane swipe |
| [1208](1208-load-failure-view.md) | Load failure view |
| [1209](1209-repo-owner-avatar.md) | Repo owner avatar |
| [1210](1210-task-status-icon-and-progress-ring.md) | Task status icon and task progress ring match the desktop frontend |
| [1211](1211-window-feedback-sound.md) | Window feedback sound on visionOS |
| [1212](1212-assistant-launcher-layout.md) | Assistant launcher layout |
| [1213](1213-blocking-connection-loss-overlay.md) | Blocking connection-loss overlay |
| [1214](1214-read-only-banner-and-pill.md) | Read-only banner and pill clearance |
| [1215](1215-remote-read-only-controls.md) | Remote read-only controls and placeholders |
| [1216](1216-connection-sheet-and-saved-connection-cards.md) | Connection sheet and saved connection cards |
| [1217](1217-loading-and-connecting-screens.md) | Loading and connecting screens |
| [1218](1218-connection-pairing-and-connections-list.md) | Pairing finalization and the connections list |
| [1219](1219-connection-failure-auto-retry.md) | Connection failure screen and auto-retry |
| [1220](1220-note-detail-loading-and-refresh.md) | Note detail loading, refresh, and links |
| [1221](1221-note-content-task-rows-and-metadata.md) | Note content task rows, metadata header, and note list rows |
| [1222](1222-manual-pairing-entry.md) | Manual pairing entry and pairing screen layout |
| [1223](1223-qr-deep-link-and-invite-pairing.md) | QR, deep-link, and invite pairing |
| [1224](1224-splash-art-and-loading-indicator.md) | Splash art and loading indicator playback |
| [1225](1225-settings-presentation-and-diagnostic-export.md) | Settings presentation and diagnostic export |
| [1301](1301-diagnostic-event-schema-and-privacy.md) | Diagnostic events carry only closed values |
| [1302](1302-diagnostic-store-writer-and-export.md) | Diagnostic store, writer and report export |
| [1303](1303-app-logging-trace-and-launch-options.md) | App logging, conversation trace and launch options |
| [1304](1304-link-and-payload-parsing.md) | Link and pairing payload parsing |
| [1305](1305-notification-alert-routing-per-backend-window.md) | Agent alerts are scoped to their source backend and window |
| [1306](1306-notification-sound-and-chime.md) | Notification sound policy and the synthesized chime |
| [1307](1307-desktop-parity-formatting-and-parsing.md) | Formatting and parsing helpers that match the desktop app |
| [1308](1308-wkwebview-javascript-call-without-swift-overlay.md) | Call page JavaScript through the Objective-C WebKit method |
| [1309](1309-agent-avatar-design-catalog.md) | The agent avatar catalog matches the desktop bit for bit |
| [1310](1310-connection-sheet-and-palette-styling.md) | Connection sheet styling and the exact design palette |
| [1311](1311-conversation-design-constants.md) | Conversation design constants and the readable column |
| [1312](1312-layout-constants-and-ipad-shell.md) | Layout constants, visionOS targets and the iPad shell |
| [1313](1313-inter-typography.md) | Inter typography tokens |
| [1314](1314-button-styles-and-visionos-hover.md) | Button styles and visionOS gaze targets |
| [1315](1315-agent-live-activity.md) | The agent Live Activity |
| [1316](1316-push-relay-link-and-device-identity.md) | Push relay linking, device identity and request proofs |
| [1401](1401-demo-mode-debug-boundary.md) | Demo mode is a Debug-only seam with production-safe flags |
| [1402](1402-demo-connection-transport.md) | The demo transport feeds fixtures through the real connection path |
| [1403](1403-demo-connection-loss-scenarios.md) | Connection-loss scenarios drive the real publisher from trigger files |
| [1404](1404-demo-fixture-responses-and-gates.md) | Demo fixture responses mirror the daemon and wait on response gates |
| [1405](1405-demo-long-conversation-fixture.md) | The long conversation fixture exercises scrolling, delegation, and hydration |
| [1406](1406-demo-controlled-end-derealization.md) | Controlled end derealization is trigger-driven and restored on evidence |
| [1407](1407-demo-inline-media-fixtures.md) | Inline media fixtures are opt-in and self-contained |
| [1408](1408-demo-design-scenarios.md) | Design scenarios are data-only fixtures behind an in-memory daemon |
| [1409](1409-demo-workspace-tool-fixtures.md) | Workspace tool fixtures stay opt-in and test-friendly |
| [1410](1410-demo-failure-and-invite-seams.md) | Failure and invite seams reach error and sheet states without a host |
| [1411](1411-demo-ui-evidence-overlays.md) | UI evidence overlays are opt-in and passive |

## 00xx records

These records came from the comment ratchet (`scripts/comment_budget.py`). They cover the ratchet itself, tests, UI tests and tooling, and use the older **Status / Context / Decision / Consequences / Code** layout. Their app-code decisions were folded into the area records above; numbers of removed 00xx records are not reused.

| ADR | Decision |
| --- | --- |
| [0001](0001-no-code-comments.md) | No code comments; decisions live in ADRs |
| [0059](0059-demo-fixtures-contract.md) | Demo fixtures are the UI test contract |
| [0084](0084-webkit-javascript-without-swift-overlay.md) | WebKit JavaScript calls avoid the Swift overlay |
| [0088](0088-bundle-and-build-contracts.md) | App bundle and build configuration contracts |
| [0089](0089-source-policy-tests.md) | Source policy tests |
| [0090](0090-test-oracles-and-fakes.md) | Test oracles, fixtures and fakes |
| [0091](0091-rendered-test-hosting.md) | Rendered unit-test hosting |
| [0092](0092-transcript-scroll-ui-tests.md) | Transcript scroll UI tests |
| [0093](0093-ui-tests-and-native-controls.md) | UI tests and native controls |
| [0094](0094-ui-test-fixtures-and-evidence.md) | UI test fixtures and evidence |
| [0095](0095-connection-loss-read-only.md) | Connection loss is read-only, not blocking |
| [0096](0096-subscription-push-routing.md) | Subscription push routing and buffering |
