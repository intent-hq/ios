# ADR-0001: No code comments; decisions live in ADRs

**Status:** Accepted, 2026-11-20

## Context

The Swift sources held about 15,200 comment lines (6.5% of all lines). An audit of a first slice (`Intent/LiveActivity`, `Intent/ViewModels`; 151 blocks) found four kinds:

| Kind | Share | Example |
| --- | --- | --- |
| Tautology | 42% | `/// The Live Activities switch changed.` above `func preferencesChanged()` |
| Decision record | 51% | Why the app accepts only `push.intentapp.dev` as a relay |
| Excuse | 7% | `// Activities are not Sendable: each helper looks one up…` above duplicated workarounds |
| Stale | 1% | `/// All transcript messages — nothing is display-filtered anymore.` |

Tautologies drift from the code. Excuses make a workaround look intentional, so agents copy it. Stale comments mislead. Decision records are valuable, but they are spread across files where nobody looks for them.

## Decision

1. Swift code in `Intent/`, `IntentTests/` and `IntentUITests/` has no comments.
2. Tool directives are not comments: `// swiftlint:`, `// periphery:` and `// fixture-protocol-version:`. Xcode section headings (`// MARK:`) are also allowed, because Xcode shows them as headings in the jump bar and minimap.
3. A decision that names and types cannot show goes into an ADR in `docs/adr/`.
4. A workaround gets an issue in `intent-hq/ios`, not a comment.
5. `scripts/comment_budget.py check` enforces this as a ratchet. `scripts/comment-budget.json` holds the comment-line count per file. New files must be at zero. A listed file can only go down, and the check fails until the baseline is lowered.
6. The `/delete-comment` skill (`.claude/skills/delete-comment/`) repeats the audit on the next slice.

## Consequences

- Deleting every comment sheds about 15,700 lines (comment lines plus the blank lines they leave).
- Reviewers see a decision record change as an ADR diff, not as a comment edit hidden in a code diff.
- The CI lint job runs the ratchet, so a new comment blocks merge.
- Doc comments no longer show in Xcode Quick Help. The names must carry that meaning.

## Code

- `scripts/comment_budget.py`, `scripts/test_comment_budget.py`, `scripts/comment-budget.json`
- `.github/workflows/ci.yml`: the **Swift comment ratchet** step
