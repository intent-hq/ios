# Architecture decision records

Swift code has no comments ([ADR 0001](0001-no-code-comments.md)). A decision that the code cannot show goes here.

| ADR | Decision |
| --- | --- |
| [0001](0001-no-code-comments.md) | No code comments; decisions live in ADRs |
| [0002](0002-push-relay-owns-live-activity.md) | The push relay owns the Live Activity once a machine links |
| [0003](0003-push-relay-trust-and-links.md) | Push relay trust, device identity and link lifecycle |
| [0004](0004-agent-questions-gating.md) | Agent Q&A pending questions gate the composer |
| [0005](0005-conversation-screen-lifecycle.md) | Conversation screen lifecycle and sending |
| [0006](0006-workspace-list-status.md) | Workspace list status, dots and groups |
| [0007](0007-agent-list-hierarchy.md) | Agent list hierarchy and order |
| [0008](0008-diagnostic-export-scope.md) | Diagnostic export scope and expiry |
| [0010](0010-agent-detail-and-summary-knowledge.md) | Agent detail and summary knowledge |
| [0011](0011-agent-list-loading-and-events.md) | Agent list loading, specialists and events |
| [0012](0012-attachment-placement-and-resolution.md) | Attachment placement and resolution |
| [0013](0013-browser-tunnel.md) | Browser tunnel |
| [0014](0014-tls-pinning-and-pairing-probe.md) | TLS pinning and the pairing certificate probe |
| [0015](0015-workspace-auxiliary-stores.md) | Workspace auxiliary stores |
| [0016](0016-live-state-subscriptions.md) | Live-state subscriptions and single-flight reads |
| [0017](0017-connection-authority-and-identity.md) | Connection authority and identity |
| [0018](0018-connection-routes-racing-and-recovery.md) | Connection routes, host racing and recovery |
| [0019](0019-composer-attachment-pipeline.md) | Composer attachment pipeline |
| [0020](0020-conversation-live-transcript.md) | Conversation live transcript |
| [0021](0021-conversation-queue-and-send-recovery.md) | Conversation queue and send recovery |
| [0022](0022-creation-catalogs-and-repo-picker.md) | Creation catalogs and the GitHub repo picker |
| [0023](0023-workspace-files-and-media.md) | Workspace files and media |
| [0024](0024-invites-and-identity-proof.md) | Invites and identity proof |
| [0025](0025-synced-backends-and-invited-sessions.md) | Synced backends and invited sessions |
| [0026](0026-audio-session-and-dictation.md) | Audio session and dictation |
| [0027](0027-notes-and-tasks.md) | Notes and tasks |
| [0028](0028-websocket-transport.md) | WebSocket transport |
| [0029](0029-workspace-stores-and-creation.md) | Workspace stores and creation |
| [0030](0030-conversation-composer-input.md) | Conversation composer input and send |
| [0031](0031-visionos-floating-composer.md) | visionOS floating composer and coverage |
| [0032](0032-transcript-notices-and-wake-cards.md) | Transcript notices and wake cards |
| [0033](0033-conversation-status-strip.md) | Conversation status strip: hooks, PR monitors and script watches |
| [0034](0034-question-wizard-presentation.md) | Question wizard presentation and attachments |
| [0035](0035-html-report-viewer-sandbox.md) | HTML report viewer sandbox |
| [0036](0036-transcript-media-and-file-viewers.md) | Transcript media and file viewers |
| [0037](0037-transcript-markdown-and-links.md) | Transcript Markdown and links |
| [0038](0038-transcript-rows-and-scroll-hosting.md) | Transcript rows, scroll hosting and conversation chrome |
| [0039](0039-transcript-copy-menu-overlay.md) | Transcript copy menu overlay and hit-testing |
| [0040](0040-agent-avatar-rows-and-history.md) | Agent avatar, row cues and agent history |
| [0041](0041-edge-drawers-and-pane-swipes.md) | Edge drawers and pane swipes |
| [0042](0042-deferred-row-snapshots.md) | Deferred row lists use Sendable snapshots |
| [0043](0043-shared-view-chrome.md) | Shared view chrome and desktop-parity components |
| [0044](0044-visionos-window-feedback-sounds.md) | visionOS window feedback sounds |
| [0045](0045-connecting-and-failure-screens.md) | Connecting and connection-failure screens |
| [0046](0046-connection-loss-windows-and-read-only-controls.md) | Connection-loss windows, the read-only pill and read-only controls |
| [0047](0047-pairing-entry-points.md) | Pairing entry points: deep link, QR, manual entry and invites |
| [0048](0048-note-detail-and-task-metadata.md) | Note detail, note links and task metadata |
| [0049](0049-workspace-screens.md) | Workspace screens: creation, pull requests, workspace page and attention |
| [0050](0050-saved-connection-registry.md) | Saved connection registry, pairing identity and legacy migration |
| [0051](0051-backend-sync-and-invited-sessions.md) | Backend registry sync and invited sessions |
| [0052](0052-daemon-wire-models.md) | Daemon wire models: tolerant decoding and vocabularies |
| [0053](0053-agent-session-display-state.md) | Agent session wire fields and display state |
| [0054](0054-transcript-attribution-and-notices.md) | Transcript row attribution and notices |
| [0055](0055-transcript-message-and-block-decoding.md) | Transcript message and block decoding |
| [0056](0056-agent-question-resource-contract.md) | Agent question resource contract |
| [0057](0057-github-and-pull-request-models.md) | GitHub repository and pull request models |
| [0058](0058-workspace-resource-models.md) | Workspace resource models: notes, tasks, scripts, changes and files |
| [0060](0060-transcript-pin-follow-takeover.md) | Transcript pin, follow and user takeover |
| [0061](0061-transcript-viewport-ownership-and-recovery.md) | Transcript viewport ownership, landing and end-row recovery |
| [0062](0062-suggested-prompt-parsing.md) | Suggested prompt parsing |
| [0063](0063-tool-row-classification.md) | Tool row classification |
| [0064](0064-markdown-parse-caches-and-link-rows.md) | Markdown parse caches and link rows |
| [0065](0065-note-checkboxes-and-row-icons.md) | Note checkboxes and row icons |
| [0066](0066-creation-picker-selection.md) | Creation picker selection |
| [0067](0067-screen-presentation-and-ipad-panes.md) | Screen presentation state and iPad panes |
| [0068](0068-launch-splash-and-connection-timing.md) | Launch, splash and connection status timing |
| [0069](0069-workspace-diff-rendering.md) | Workspace diff rendering |
| [0070](0070-backend-bound-windows-and-sessions.md) | Backend-bound windows and shared backend sessions |
| [0071](0071-connection-loss-and-recovery.md) | Connection screens, connection loss and recovery |
| [0072](0072-deep-links-and-invites.md) | Deep links and workspace invites |
| [0073](0073-screen-restoration-and-route-validation.md) | Screen restoration and route validation |
| [0074](0074-ipad-shell-and-root-layout.md) | iPad shell navigation and root layout |
| [0080](0080-diagnostic-history-privacy-and-storage.md) | Diagnostic history privacy, bounds and storage |
| [0081](0081-links-from-agents-and-daemons.md) | Links from agents and daemons |
| [0082](0082-agent-alert-suppression-routing-and-sound.md) | Agent alerts: suppression, window routing and sound |
| [0083](0083-desktop-parity-ports.md) | Desktop parity ports |
| [0084](0084-webkit-javascript-without-swift-overlay.md) | WebKit JavaScript calls avoid the Swift overlay |
| [0085](0085-demo-mode-boundaries.md) | Demo mode boundaries and opt-in scenarios |
| [0086](0086-design-tokens-from-figma.md) | Design tokens from Figma |
| [0087](0087-visionos-gaze-and-hit-targets.md) | visionOS gaze highlights and hit targets |
| [0090](0090-test-oracles-and-fakes.md) | Test oracles, fixtures and fakes |
| [0091](0091-rendered-test-hosting.md) | Rendered unit-test hosting |
| [0096](0096-subscription-push-routing.md) | Subscription push routing and buffering |
| [0100](0100-live-subscription-snapshots.md) | Live subscription snapshots and deltas |
| [0101](0101-demo-fixtures-contract.md) | Demo fixtures are the UI test contract |
| [0102](0102-dictation-merge-rules.md) | Dictation merge rules |
| [0103](0103-daemon-event-classification.md) | Daemon event classification and wake labels |
| [0104](0104-test-synchronization-and-fakes.md) | Test synchronization and connection fakes |
| [0105](0105-github-repo-and-branch-caches.md) | GitHub repo and branch caches |
| [0106](0106-note-store-cache-and-hydration.md) | Note store cache, hydration and not-found |
| [0107](0107-bundle-and-build-contracts.md) | App bundle and build configuration contracts |
| [0108](0108-source-policy-tests.md) | Source policy tests |
| [0110](0110-transcript-scroll-ui-tests.md) | Transcript scroll UI tests |
| [0111](0111-ui-tests-and-native-controls.md) | UI tests and native controls |
| [0112](0112-ui-test-fixtures-and-evidence.md) | UI test fixtures and evidence |
| [0113](0113-connection-loss-read-only.md) | Connection loss is read-only, not blocking |

## Format

Each record has **Status**, **Context**, **Decision**, **Consequences** and **Code**. **Code** names the types and members that apply the decision, so a reader can go from the code to the record with a search for the type name.

Write a new record as `NNNN-short-title.md` with the next number, and add it to the table. Do not edit an accepted decision. Write a new record that supersedes it, and set the old status to `Superseded by NNNN`.
