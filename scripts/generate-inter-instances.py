#!/usr/bin/env python3
"""Build the design's static 450/550 faces from the pinned Inter 4.1 release.

Run: uv run --with fonttools==4.66.0 scripts/generate-inter-instances.py Inter-4.1.zip
"""

import copy
import hashlib
import io
from pathlib import Path
import sys
import zipfile

from fontTools.ttLib import TTFont
from fontTools.varLib.instancer import instantiateVariableFont

ARCHIVE_SHA256 = "9883fdd4a49d4fb66bd8177ba6625ef9a64aa45899767dde3d36aa425756b11e"
FACES = {"Regular": 450, "Italic": 450, "Medium": 550, "MediumItalic": 550}
FONT_DIRECTORY = Path(__file__).resolve().parent.parent / "Intent/Resources/Fonts/Inter"


def main():
    archive_bytes = Path(sys.argv[1]).read_bytes()
    if hashlib.sha256(archive_bytes).hexdigest() != ARCHIVE_SHA256:
        raise SystemExit("Expected the official Inter-4.1.zip release archive.")
    with zipfile.ZipFile(io.BytesIO(archive_bytes)) as archive:
        for face, weight in FACES.items():
            name = f"Inter-{face}"
            original = TTFont(io.BytesIO(archive.read(f"extras/ttf/{name}.ttf")))
            source = "InterVariable-Italic.ttf" if "Italic" in face else "InterVariable.ttf"
            variable = TTFont(io.BytesIO(archive.read(source)), recalcTimestamp=False)
            font = instantiateVariableFont(variable, {"opsz": 14, "wght": weight}, inplace=True)
            font["name"] = copy.deepcopy(original["name"])
            font["OS/2"].fsSelection = original["OS/2"].fsSelection
            font["head"].macStyle = original["head"].macStyle
            font["name"].setName(f"Inter 4.1 static instance, weight {weight}, optical size 14.", 10, 3, 1, 0x409)
            font.save(FONT_DIRECTORY / f"{name}.ttf")
            print(f"{name}: static weight {weight}")


if __name__ == "__main__":
    main()
