---
name: delete-comment
description: Audit and delete Swift code comments in a slice of the iOS repo. Sort each comment as tautology, excuse, stale, or decision record; delete it, file an issue for each excuse, move each decision into an ADR, and lower the comment ratchet. Use when asked to delete, audit or burn down comments, or to run /delete-comment with a path.
---

# Delete comments

Code in this repo has no comments ([ADR 0001](../../../docs/adr/0001-no-code-comments.md)). `scripts/comment-budget.json` lists the files that still have comments. This skill removes the comments in one slice.

Argument: one or more directories or files, for example `/delete-comment Intent/Models`. With no argument, pick the next slice yourself (step 1).

## 1. Choose a slice

Keep one slice to about 150 comment blocks, so one agent can judge each block.

```bash
python3 scripts/comment_budget.py estimate
python3 scripts/comment_budget.py inventory Intent/Models | grep -c '^=='
```

To find small directories, run `inventory` on each and count the `==` lines. Do not split a type across two slices.

## 2. Read the inventory

```bash
python3 scripts/comment_budget.py inventory <slice> > "$TMPDIR/inventory.txt"
```

Each block shows `path:lines kind`, the comment, and `->` the next code line. Read the code around a block when the next line is not enough. Tool directives (`// swiftlint:`, `// periphery:`, `// fixture-protocol-version:`) and `// MARK:` section headings are not in the inventory. Keep them.

## 3. Sort each block

Give every block exactly one category. Record it in a scratch table in `$TMPDIR` (`path:lines | category | target`). You need it for the PR body.

| Category | Test | Action |
| --- | --- | --- |
| **Tautology** | Says what the name, type, signature or next lines already say. Includes unit notes (`// 30 minutes`), "Starts X", "The Y changed". | Delete. |
| **Stale** | Names code, files, behaviour or history that no longer exists or no longer applies ("anymore", "was", "old", removed symbols, decision ids nobody can find). Check with `grep`. | Delete. |
| **Excuse** | Explains why a workaround, duplicate, suppression, swallowed error, legacy branch, or cache trick is acceptable. Signs: "not Sendable so…", "must read X even on a hit", `catch {}`, `swiftlint:disable` with a reason, "old daemons…", "may arrive while…". | Delete. File one issue per workaround (step 5). |
| **Decision record** | States an important, non-obvious rule that the code cannot show: a security boundary, a protocol or wire contract, an ordering or precedence rule, a race rule, desktop parity, a product rule. | Delete. Move the rule into an ADR (step 4). |

Rules:

1. When in doubt between tautology and decision record, ask: "Would a careful engineer break something without this?" No → tautology.
2. When in doubt between decision record and excuse, ask: "Is the code shaped this way on purpose, or because a better shape was too much work?" Too much work → excuse.
3. A stale comment can still hold a live decision. Move the live part into the ADR and record the block as stale.
4. Do not rename or refactor code in this skill. A comment that wants a better name is a tautology plus, at most, a follow-up issue.

## 4. Write the ADRs

1. Read `docs/adr/README.md`. Add to an existing ADR when its topic matches and it is not accepted for another reason. Otherwise create `docs/adr/NNNN-short-title.md` with the next number.
2. Group by topic, not by file: one ADR for a feature's rules, not one per comment.
3. Use the README format: **Status**, **Context**, **Decision** (numbered), **Consequences**, **Code**. Write short, plain sentences in Simplified Technical English. Keep issue and protocol references (`intent-hq/intentd#743`, `PROTOCOL §5.5`).
4. In **Code**, name the types and members (`Type`: `member(_:)`), never line numbers.
5. Grep each symbol you name; it must exist.
6. Add the ADR to the README table.

## 5. File issues for excuses

Follow `AGENTS.md` → Issues and pull requests.

1. Search first: `gh issue list --repo intent-hq/ios --search "<keywords>" --state all`. Comment on a match instead of filing a new one.
2. One issue per workaround. Group excuses that describe the same workaround.
3. Title: conventional prefix (`refactor:` or `fix:`) and the target shape.
4. Body: **Problem** (what the code does and what the deleted comment excused), **Fix** (the better shape), **Code** (files and members). Mention that the comment was removed under docs/adr/0001.
5. `gh issue create --repo intent-hq/ios --label component:ios,agent-filed --title "…" --body-file "$TMPDIR/issue.md"`

## 6. Delete the comments

```bash
python3 scripts/comment_budget.py strip <files...>              # every comment in each file
python3 scripts/comment_budget.py strip Intent/A.swift:40-52     # only a line range
```

`strip` keeps tool directives and string contents. It removes blank lines that the deletion leaves after `{`, before `}`, at the top of the file, or doubled. Then:

1. Run `python3 scripts/comment_budget.py inventory <slice>`; it must print nothing for fully stripped files.
2. `grep -rn '{  *}' <slice>`: replace `{ }` left by a removed inline block comment with `{}`.
3. `git diff` the slice and read it. Only comment lines and blank lines may change.
4. Grep `IntentTests/` and `IntentUITests/` for paths in the slice (`"Intent/<slice>/`). A source-backed policy test that reads a comment must change in the same commit.

## 7. Lower the ratchet and check

```bash
python3 scripts/comment_budget.py update
python3 scripts/comment_budget.py check
```

`update` only lowers the baseline. If it fails, a file gained comments: remove them, do not raise the baseline.

Comment-only diffs do not change compiled code, so a Swift build is not needed. Run `scripts/swiftlint.sh` when SwiftLint is set up (`vertical_whitespace*` rules check the blank lines).

## 8. Commit and report

1. Commit: `refactor: delete comments in <slice>` with the category counts in the body.
2. In the PR body, add a table: category, count, action; list the ADRs and the issue numbers.
3. Report `python3 scripts/comment_budget.py estimate` before and after the slice.
