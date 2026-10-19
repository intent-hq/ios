#!/usr/bin/env python3
"""Select one explicitly assigned iPhone UI smoke shard."""

import argparse
from pathlib import Path
import re


SELECTOR = re.compile(r"IntentUITests/[A-Za-z_][A-Za-z0-9_]*/test[A-Za-z0-9_]*")
ANNOTATION = re.compile(r"shard:\s*([12])")


def load_shards(path):
    """Return ordered selectors for both shards, rejecting incomplete input."""
    path = Path(path)
    shards = {1: [], 2: []}
    seen = set()
    for number, raw in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        selector, _, annotation = line.partition("#")
        selector = selector.strip()
        if not SELECTOR.fullmatch(selector):
            raise ValueError(f"{path}:{number}: malformed UI test selector")
        match = ANNOTATION.fullmatch(annotation.strip())
        if not match:
            raise ValueError(f"{path}:{number}: expected # shard: 1 or # shard: 2")
        if selector in seen:
            raise ValueError(f"{path}:{number}: duplicate selector: {selector}")
        seen.add(selector)
        shards[int(match[1])].append(selector)
    for shard, selectors in shards.items():
        if not selectors:
            raise ValueError(f"{path}: shard {shard} has no selectors")
    return shards


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--shard", required=True, choices=("1", "2"))
    args = parser.parse_args()
    try:
        shards = load_shards(Path(__file__).with_name("ui-smoke-tests.txt"))
    except (OSError, UnicodeError, ValueError) as error:
        parser.error(str(error))
    print(" ".join(shards[int(args.shard)]))


if __name__ == "__main__":
    main()
