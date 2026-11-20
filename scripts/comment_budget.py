#!/usr/bin/env python3
"""Ratchet Swift comments down to zero.

Code must explain itself; decisions live in docs/adr/. New files may hold no
comments and listed files may only lose them. Tool directives that change
behaviour (`// swiftlint:`, `// periphery:`, `// fixture-protocol-version:`)
are exempt.

  check                     fail on new comments or a stale baseline
  update                    lower the baseline to current counts (never raises)
  estimate                  print the lines that deleting every comment sheds
  inventory [PATH ...]      list comment blocks with the code they annotate
  strip PATH[:A[-B]] ...    delete comments (whole file or a line range)
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
from dataclasses import dataclass
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
BASELINE = Path("scripts/comment-budget.json")
SOURCE_ROOTS = ("Intent", "IntentTests", "IntentUITests")
DIRECTIVE = re.compile(r"^(?://|/\*)\s*(?:swiftlint|periphery|fixture-protocol-version):")
REGEX_PREFIXES = set("(,=:[{;!&|?")
WHITESPACE = " \t\r\n"

NONE, COUNTED, DIRECTIVE_MARK = 0, 1, 2


class LexError(ValueError):
    pass


def _skip_back(code: list[str], index: int) -> int:
    while index >= 0 and code[index] in WHITESPACE:
        index -= 1
    return index


def _block_end(src: str, start: int) -> int:
    depth, index = 0, start
    while index < len(src):
        if src.startswith("/*", index):
            depth += 1
            index += 2
        elif src.startswith("*/", index):
            depth -= 1
            index += 2
            if depth == 0:
                return index
        else:
            index += 1
    raise LexError("unclosed block comment")


def _string_end(src: str, start: int, spans: list[tuple[int, int]] | None = None, code: list[str] | None = None) -> int | None:
    index = start
    while index < len(src) and src[index] == "#":
        index += 1
    hashes = index - start
    if index >= len(src) or src[index] != '"':
        return None
    multiline = re.compile(r'"""[ \t]*(?:\n|$)')
    quotes = '"""' if multiline.match(src, index) else '"'
    index += len(quotes)
    closing = quotes + "#" * hashes
    escape = "\\" + "#" * hashes
    while index < len(src):
        if src.startswith(closing, index):
            return index + len(closing)
        if len(quotes) == 1 and src[index] == "\n":
            raise LexError("unclosed string literal")
        if src.startswith(escape, index):
            index += len(escape)
            if index < len(src) and src[index] == "(":
                index = _interpolation_end(src, index, spans, code)
            else:
                index += 1
        else:
            index += 1
    raise LexError("unclosed string literal")


def _blank(code: list[str], start: int, end: int) -> None:
    for index in range(start, end):
        if code[index] != "\n":
            code[index] = " "


def _interpolation_end(src: str, opener: int, spans: list[tuple[int, int]] | None = None, code: list[str] | None = None) -> int:
    """Scan an interpolation as Swift code, like `comment_spans`: nested
    literals (strings and regexes) and comments are skipped lexically and
    blanked in `code`, so a later bare regex sees the real preceding token,
    and comments are recorded in `spans`."""
    if code is None:
        code = list(src)
    depth, index = 0, opener
    while index < len(src):
        start = index
        if src.startswith("//", index):
            newline = src.find("\n", index)
            index = len(src) if newline < 0 else newline
            if spans is not None:
                spans.append((start, index))
        elif src.startswith("/*", index):
            index = _block_end(src, index)
            if spans is not None:
                spans.append((start, index))
        else:
            literal = _regex_end(src, index, code)
            if literal is None:
                literal = _string_end(src, index, spans, code)
            if literal is None:
                if src[index] == "(":
                    depth += 1
                elif src[index] == ")":
                    depth -= 1
                    if depth == 0:
                        return index + 1
                index += 1
                continue
            index = literal
        _blank(code, start, index)
    raise LexError("unclosed interpolation")


def _regex_end(src: str, start: int, code: list[str]) -> int | None:
    index = start
    while index < len(src) and src[index] == "#":
        index += 1
    hashes = index - start
    if index + 1 >= len(src) or src[index] != "/":
        return None
    if hashes == 0:
        previous = _skip_back(code, start - 1)
        following = src[index + 1]
        if previous >= 0 and code[previous] not in REGEX_PREFIXES:
            return None
        if following in WHITESPACE or following in "/*":
            return None
    closing = "/" + "#" * hashes
    index += 1
    class_depth = 0
    while index < len(src):
        char = src[index]
        if hashes == 0 and char == "\n":
            return None
        if char == "\\":
            index += 2
            continue
        if char == "[":
            class_depth += 1
        elif char == "]" and class_depth > 0:
            class_depth -= 1
        if class_depth == 0 and src.startswith(closing, index):
            return index + len(closing)
        index += 1
    raise LexError("unclosed regex literal")


def comment_spans(src: str) -> list[tuple[int, int]]:
    """Offsets of every comment, skipping string and regex literals."""
    code = list(src)
    spans: list[tuple[int, int]] = []
    index = 0
    while index < len(src):
        start = index
        if src.startswith("//", index):
            newline = src.find("\n", index)
            index = len(src) if newline < 0 else newline
            spans.append((start, index))
        elif src.startswith("/*", index):
            index = _block_end(src, index)
            spans.append((start, index))
        else:
            end = _string_end(src, index, spans, code)
            if end is None:
                end = _regex_end(src, index, code)
            if end is None:
                index += 1
                continue
            index = end
        for blank in range(start, index):
            if code[blank] != "\n":
                code[blank] = " "
    return sorted(spans)


@dataclass
class Line:
    number: int
    text: str
    counted: bool
    comment_only: bool


def classify(src: str) -> list[Line]:
    marks = [NONE] * len(src)
    for start, end in comment_spans(src):
        kind = DIRECTIVE_MARK if DIRECTIVE.match(src[start:end]) else COUNTED
        marks[start:end] = [kind] * (end - start)
    lines, offset = [], 0
    for number, text in enumerate(src.split("\n"), start=1):
        visible = [marks[offset + i] for i, char in enumerate(text) if char not in WHITESPACE]
        counted = COUNTED in visible
        lines.append(Line(number, text, counted, counted and all(mark == COUNTED for mark in visible)))
        offset += len(text) + 1
    return lines


def swift_files(root: Path) -> list[Path]:
    files = []
    for source_root in SOURCE_ROOTS:
        for directory, _, names in os.walk(root / source_root):
            files += [Path(directory, name) for name in names if name.endswith(".swift")]
    return sorted(files)


def read(path: Path) -> str:
    return path.read_text(encoding="utf-8")


def counts(root: Path) -> dict[str, int]:
    result = {}
    for path in swift_files(root):
        relative = path.relative_to(root).as_posix()
        try:
            total = sum(line.counted for line in classify(read(path)))
        except LexError as error:
            raise SystemExit(f"error: {relative}: {error}") from error
        if total:
            result[relative] = total
    return result


def load_baseline(root: Path) -> dict[str, int]:
    path = root / BASELINE
    return json.loads(read(path))["files"] if path.exists() else {}


def write_baseline(root: Path, files: dict[str, int]) -> None:
    body = {"files": dict(sorted(files.items()))}
    (root / BASELINE).write_text(json.dumps(body, indent=2) + "\n", encoding="utf-8")


def problems(current: dict[str, int], baseline: dict[str, int]) -> list[str]:
    found = []
    for path, count in sorted(current.items()):
        budget = baseline.get(path, 0)
        if count > budget:
            found.append(f"{path}: {count} comment lines (budget {budget}). Name the code so it explains itself; record decisions in docs/adr/.")
        elif count < budget:
            found.append(f"{path}: dropped to {count} comment lines; run `python3 scripts/comment_budget.py update`.")
    for path in sorted(set(baseline) - set(current)):
        found.append(f"{path}: has no comments left; run `python3 scripts/comment_budget.py update`.")
    return found


def command_check(root: Path) -> int:
    found = problems(counts(root), load_baseline(root))
    for problem in found:
        print(f"error: {problem}", file=sys.stderr)
    return 1 if found else 0


def command_update(root: Path) -> int:
    current, baseline = counts(root), load_baseline(root)
    raised = [path for path, count in current.items() if count > baseline.get(path, 0)]
    if raised and (root / BASELINE).exists():
        for path in sorted(raised):
            print(f"error: {path}: {current[path]} comment lines exceed budget {baseline.get(path, 0)}; the baseline only goes down.", file=sys.stderr)
        return 1
    write_baseline(root, current)
    print(f"baseline: {sum(current.values())} comment lines in {len(current)} files")
    return 0


def command_estimate(root: Path) -> int:
    rows: dict[str, list[int]] = {}
    for path in swift_files(root):
        lines = classify(read(path))
        group = path.relative_to(root).parts[0]
        comment_only = [line.number for line in lines if line.comment_only]
        row = rows.setdefault(group, [0, 0, 0, 0])
        row[0] += len(lines)
        row[1] += sum(line.counted for line in lines)
        row[2] += len(comment_only)
        row[3] += len(comment_only) + len(_orphaned_blanks(lines, set(comment_only)))
    print(f"{'target':<15}{'lines':>9}{'comment':>9}{'own-line':>10}{'shed':>8}")
    for group, (total, counted, own, shed) in sorted(rows.items()):
        print(f"{group:<15}{total:>9}{counted:>9}{own:>10}{shed:>8}")
    totals = [sum(row[i] for row in rows.values()) for i in range(4)]
    print(f"{'total':<15}{totals[0]:>9}{totals[1]:>9}{totals[2]:>10}{totals[3]:>8}")
    return 0


def _blocks(lines: list[Line]):
    index = 0
    while index < len(lines):
        line = lines[index]
        if line.comment_only:
            end = index
            while end + 1 < len(lines) and lines[end + 1].comment_only:
                end += 1
            yield "own-line", lines[index:end + 1], end + 1
            index = end + 1
        elif line.counted:
            yield "trailing", [line], index
            index += 1
        else:
            index += 1


def command_inventory(root: Path, targets: list[str]) -> int:
    paths = [p for p in swift_files(root) if not targets or any(p.relative_to(root).as_posix().startswith(t) for t in targets)]
    for path in paths:
        relative = path.relative_to(root).as_posix()
        lines = classify(read(path))
        for kind, block, after in _blocks(lines):
            context = next((l.text.strip() for l in lines[after:] if l.text.strip() and not l.comment_only), "")
            span = f"{block[0].number}" if len(block) == 1 else f"{block[0].number}-{block[-1].number}"
            print(f"== {relative}:{span} {kind}")
            for line in block:
                print(f"   {line.text.strip()}")
            if kind == "own-line":
                print(f"   -> {context[:160]}")
    return 0


def _orphaned_blanks(lines: list[Line], removed: set[int]) -> set[int]:
    kept = [line for line in lines if line.number not in removed]
    drop, before = set(), ""
    for position, line in enumerate(kept):
        if line.text.strip():
            before = line.text.rstrip()
            continue
        at_end = position + 1 == len(kept)
        after = "" if at_end else kept[position + 1].text.lstrip()
        beside_removed = line.number - 1 in removed or line.number + 1 in removed
        if beside_removed and (not before or before.endswith("{") or after.startswith("}") or at_end):
            drop.add(line.number)
        else:
            before = ""
    return drop


def strip_source(src: str, selected: set[int] | None = None) -> str:
    """Delete counted comments on the selected lines (all lines when None)."""
    lines = classify(src)
    spans = [(s, e) for s, e in comment_spans(src) if not DIRECTIVE.match(src[s:e])]
    chosen = {line.number for line in lines if line.counted and (selected is None or line.number in selected)}
    removed = {number for number in chosen if lines[number - 1].comment_only}
    pieces, cursor = [], 0
    for start, end in spans:
        first = src.count("\n", 0, start) + 1
        last = first + src.count("\n", start, end)
        if not any(number in chosen for number in range(first, last + 1)):
            continue
        pieces.append(src[cursor:start])
        before = src[start - 1] if start > 0 else "\n"
        after = src[end] if end < len(src) else "\n"
        newlines = src.count("\n", start, end)
        pieces.append("\n" * newlines)
        if newlines and after != "\n":
            line_start = src.rfind("\n", 0, start) + 1
            indent = src[line_start:start]
            pieces.append(indent[:len(indent) - len(indent.lstrip(" \t"))])
            while end < len(src) and src[end] in " \t":
                end += 1
        elif before not in WHITESPACE and after not in WHITESPACE:
            pieces.append(" ")
        elif before in " \t" and after in " \t":
            end += 1
        elif before in " \t" and after in ")]},;:.":
            pieces[-2] = pieces[-2].rstrip(" \t")
        cursor = end
    pieces.append(src[cursor:])
    edited = "".join(pieces).split("\n")
    drop = removed | _orphaned_blanks(lines, removed)
    output = []
    for line, new_text in zip(lines, edited):
        if line.number in drop:
            continue
        output.append(new_text.rstrip() if line.number in chosen else new_text)
    return "\n".join(output)


def _parse_target(target: str) -> tuple[str, set[int] | None]:
    match = re.fullmatch(r"(.+?\.swift)(?::(\d+)(?:-(\d+))?)?", target)
    if not match:
        raise SystemExit(f"error: expected PATH.swift[:START[-END]], got {target}")
    path, start, end = match.groups()
    if start is None:
        return path, None
    return path, set(range(int(start), int(end or start) + 1))


def command_strip(root: Path, targets: list[str]) -> int:
    by_path: dict[str, set[int] | None] = {}
    for target in targets:
        path, selected = _parse_target(target)
        whole_file = selected is None or (path in by_path and by_path[path] is None)
        by_path[path] = None if whole_file else (by_path.get(path) or set()) | selected
    for path, selected in by_path.items():
        file = root / path
        file.write_text(strip_source(read(file), selected), encoding="utf-8")
    return 0


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("command", choices=["check", "update", "estimate", "inventory", "strip"], nargs="?", default="check")
    parser.add_argument("targets", nargs="*")
    parser.add_argument("--root", type=Path, default=REPO_ROOT)
    args = parser.parse_args(argv)
    root = args.root.resolve()
    if args.command == "inventory":
        return command_inventory(root, args.targets)
    if args.command == "strip":
        return command_strip(root, args.targets)
    return {"check": command_check, "update": command_update, "estimate": command_estimate}[args.command](root)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
