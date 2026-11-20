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

## Format

Each record has **Status**, **Context**, **Decision**, **Consequences** and **Code**. **Code** names the types and members that apply the decision, so a reader can go from the code to the record with a search for the type name.

Write a new record as `NNNN-short-title.md` with the next number, and add it to the table. Do not edit an accepted decision. Write a new record that supersedes it, and set the old status to `Superseded by NNNN`.
