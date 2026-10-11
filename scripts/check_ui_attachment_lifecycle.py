#!/usr/bin/env python3
"""Reject UI-test attachments produced from Swift defer, including helper calls.

This is a conservative source contract, not Swift type checking: function names
are combined across IntentUITests (including extensions/overloads), and XCTest's
add and XCTAttachment are attachment sinks. Named helper functions are followed
transitively, including parameter defaults. This does not resolve dynamic
dispatch, function-value aliases, computed properties, or constructors.
Comments/string text are ignored, but interpolation expressions remain code.
Ordinary cleanup defer blocks remain valid.
"""

import argparse
from collections import defaultdict
from pathlib import Path
import re
import sys


def code_only(source):
    """Blank non-code without shifting offsets; handle nested comments/raw strings."""
    output = list(source)

    def blank(start, end):
        output[start:end] = ["\n" if char == "\n" else " " for char in source[start:end]]

    def string(start, hashes, quote):
        opening = hashes + quote
        closing = quote + hashes
        escape = "\\" + hashes
        cursor = start + len(opening)
        blank(start, cursor)
        while cursor < len(source):
            if source.startswith(closing, cursor):
                blank(cursor, cursor + len(closing))
                return cursor + len(closing)
            if source.startswith(escape + "(", cursor):
                blank(cursor, cursor + len(escape))
                cursor = code(cursor + len(escape) + 1, ")")
            elif source.startswith(escape, cursor):
                end = min(len(source), cursor + len(escape) + 1)
                blank(cursor, end)
                cursor = end
            else:
                blank(cursor, cursor + 1)
                cursor += 1
        raise ValueError("unterminated Swift string")

    def code(cursor, closing=None):
        while cursor < len(source):
            if source.startswith("//", cursor):
                end = source.find("\n", cursor)
                end = len(source) if end == -1 else end
                blank(cursor, end)
                cursor = end
            elif source.startswith("/*", cursor):
                start, depth = cursor, 1
                cursor += 2
                while cursor < len(source) and depth:
                    if source.startswith("/*", cursor):
                        depth += 1
                        cursor += 2
                    elif source.startswith("*/", cursor):
                        depth -= 1
                        cursor += 2
                    else:
                        cursor += 1
                if depth:
                    raise ValueError("unterminated Swift comment")
                blank(start, cursor)
            elif match := re.match(r'(\#*)("""|")', source[cursor:]):
                cursor = string(cursor, *match.groups())
            elif source[cursor] == "(":
                cursor = code(cursor + 1, ")")
            elif closing and source[cursor] == closing:
                return cursor + 1
            else:
                cursor += 1
        if closing:
            raise ValueError("unclosed Swift interpolation or parentheses")
        return cursor

    code(0)
    return "".join(output)


def source_blocks(source):
    """Return symbol dependencies and defer bodies with their original line numbers."""
    masked = code_only(source)
    matches = list(re.finditer(r'`[^`\n]+`|[A-Za-z_][A-Za-z_0-9]*|[^\s]', masked))
    tokens = [match.group().strip("`") for match in matches]
    pairs, stack = {}, []
    for index, token in enumerate(tokens):
        if token in ("{", "(", "["):
            stack.append(index)
        elif token in ("}", ")", "]"):
            if not stack or tokens[stack[-1]] != {"}": "{", ")": "(", "]": "["}[token]:
                raise ValueError("unbalanced Swift delimiters")
            pairs[stack.pop()] = index
    if stack:
        raise ValueError("unclosed Swift delimiters")

    def default_references(start, end):
        references = set()
        cursor = start + 1
        while cursor < end:
            if tokens[cursor] == "=":
                cursor += 1
                while cursor < end and tokens[cursor] != ",":
                    stop = pairs[cursor] + 1 if tokens[cursor] in ("(", "[", "{") else cursor + 1
                    references.update(tokens[cursor:stop])
                    cursor = stop
            elif tokens[cursor] in ("(", "[", "{"):
                cursor = pairs[cursor] + 1
            else:
                cursor += 1
        return references

    dependencies = defaultdict(set)
    deferred = []
    for index, token in enumerate(tokens):
        if token == "defer" and tokens[index + 1:index + 2] == ["{"]:
            end = pairs[index + 1]
            line = source.count("\n", 0, matches[index].start()) + 1
            deferred.append((line, set(tokens[index + 2:end])))
        if token != "func" or index + 2 >= len(tokens):
            continue
        name = tokens[index + 1]
        cursor = index + 2
        while cursor < len(tokens):
            current = tokens[cursor]
            if current in (";", "}", "func", "let", "var"):
                break
            if current in ("(", "["):
                dependencies[name].update(default_references(cursor, pairs[cursor]))
                cursor = pairs[cursor] + 1
                continue
            if current == "{":
                dependencies[name].update(tokens[cursor + 1:pairs[cursor]])
                break
            cursor += 1
    return dependencies, deferred


def violations(sources):
    """Map of relative Swift paths to text in; (path, line, producer) tuples out."""
    dependencies = defaultdict(set)
    deferred = []
    for path, source in sorted(sources.items()):
        try:
            symbols, bodies = source_blocks(source)
        except ValueError as error:
            raise ValueError(f"{path}: {error}") from error
        for name, references in symbols.items():
            dependencies[name].update(references)
        deferred.extend((path, line, references) for line, references in bodies)

    producers = {"XCTAttachment", "add"}
    while additions := {name for name, references in dependencies.items()
                        if name not in producers and references & producers}:
        producers.update(additions)
    return [(path, line, ", ".join(sorted(references & producers)))
            for path, line, references in deferred if references & producers]


def check(root):
    directory = root / "IntentUITests"
    paths = sorted(directory.rglob("*.swift"))
    if not paths:
        raise ValueError(f"No Swift UI test sources found in {directory}")
    sources = {path.relative_to(root).as_posix(): path.read_text(encoding="utf-8") for path in paths}
    found = violations(sources)
    for path, line, producers in found:
        print(f"{path}:{line}: attachment-producing defer ({producers}); use "
              "addTeardownBlock with @MainActor async capture before cleanup", file=sys.stderr)
    if not found:
        print(f"UI attachment lifecycle: checked {len(paths)} Swift files; no attachment-producing defer blocks.")
    return 1 if found else 0


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[1])
    args = parser.parse_args()
    try:
        return check(args.root)
    except (OSError, ValueError) as error:
        print(f"UI attachment lifecycle check failed: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
