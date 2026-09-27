"""Bounded append-only entry insertion. Existing PM copy is never regenerated.

Markers bind a build/channel identity to the original immutable payload, not to
editable Markdown bytes. Replays with that original payload are no-ops even after
PM edits; a different baseline/payload for the same identity requires human review.
Unknown/duplicate headings or malformed markers stop rather than rewrite history.
"""

import re
import release_notes as notes

MAX_DOCUMENT = 1024 * 1024
MARKER = re.compile(r"^<!-- intent-release-entry ([A-Za-z0-9:.-]+) ([0-9a-f]{64}) -->$", re.M)
END = "<!-- /intent-release-entry -->"


def order(version):
    parts = [int(p) for p in notes.version(version).split(".")]
    return tuple(parts + [0] * (3 - len(parts)))


def insert(document, payload):
    notes.require(isinstance(document, str) and len(document.encode()) <= MAX_DOCUMENT and "\x00" not in document,
                  "Changelog is missing, malformed or oversized.")
    notes.require(document.startswith("# Changelog\n") and document.endswith("\n"), "Review the root changelog format before publication.")
    versions = list(re.finditer(r"^## (.+)$", document, re.M))
    numbers = [order(m[1]) for m in versions]
    notes.require(len(numbers) == len(set(numbers)) and numbers == sorted(numbers, reverse=True), "Version headings must be unique and newest first.")
    entries = list(MARKER.finditer(document))
    notes.require(len(entries) <= 1000 and len(entries) == document.count("<!-- intent-release-entry") == document.count(END),
                  "Ambiguous entry markers; preserve history and reconcile manually.")
    seen = set()
    for entry in entries:
        key, digest = entry[1], entry[2]
        notes.require(key not in seen, "Duplicate changelog entry identity.")
        seen.add(key)
        stop = document.find(END, entry.end())
        notes.require(stop >= 0 and "<!-- intent-release-entry" not in document[entry.end():stop], "Overlapping entry markers.")
        parts = key.split(":")
        notes.require(len(parts) == 6 and parts[1] == "IOS" and parts[3] in ("beta", "app-store") and parts[5] == "en-US",
                      "Invalid changelog identity marker.")
        prior = [m for m in versions if m.start() < entry.start()]
        notes.require(prior and prior[-1][1] == parts[2], "Entry is under the wrong version.")
        sections = list(re.finditer(r"^### (.+)$", document[prior[-1].end():entry.start()], re.M))
        notes.require(sections and sections[-1][1] == ("Beta" if parts[3] == "beta" else "App Store"), "Entry is under the wrong channel.")
        notes.require(not re.search(r"^#{2,3} ", document[entry.end():stop], re.M), "Entry crosses a section boundary.")
        if key == payload["entry_key"]:
            notes.require(digest == payload["content_sha256"], "Existing build has another original payload; preserve PM edits and reconcile.")
    # Validate all section layouts even on no-op replays.
    for index, version in enumerate(versions):
        end = versions[index + 1].start() if index + 1 < len(versions) else len(document)
        sections = re.findall(r"^### (.+)$", document[version.end():end], re.M)
        notes.require(sections == ["Beta", "App Store"], "Each version needs exactly Beta then App Store sections.")
    if payload["entry_key"] in seen:
        return document
    notes.require(payload["entry_key"] not in document, "Unmarked existing entry; reconcile ownership instead of duplicating.")
    block = f"<!-- intent-release-entry {payload['entry_key']} {payload['content_sha256']} -->\n{payload['markdown_entry']}{END}\n\n"
    version = payload["candidate"]["version"]
    existing = next((m for m in versions if m[1] == version), None)
    if existing is None:
        notes.require(order(version) not in numbers, "Equivalent version spelling already exists; reconcile manually.")
        position = next((m.start() for m in versions if order(m[1]) < order(version)), len(document))
        beta = block if payload["channel"] == "beta" else ""
        store = block if payload["channel"] == "app-store" else ""
        addition = f"## {version}\n\n### Beta\n\n{beta}### App Store\n\n{store}"
    else:
        end = next((m.start() for m in versions if m.start() > existing.start()), len(document))
        section = re.search(r"^" + re.escape(payload["channel_heading"]) + r"\n", document[existing.end():end], re.M)
        notes.require(section is not None, "Missing channel heading.")
        position = existing.end() + section.end()
        addition = "\n" + block
    result = document[:position] + addition + document[position:]
    notes.require(len(result.encode()) <= MAX_DOCUMENT, "Changelog exceeds the publication bound; review manually.")
    return result