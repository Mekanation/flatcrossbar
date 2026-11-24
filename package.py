"""Builds the CurseForge upload: flatcrossbar/dist/FlatCrossbar-<version>.zip.

The zip holds one top-level FlatCrossbar/ folder (the addon only: no tests, no
README) with forward-slash paths, which Windows' own "Send to > Compressed
folder" and Compress-Archive do not produce and CurseForge rejects.

Run:  python flatcrossbar/package.py
"""
import re
import sys
import zipfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
ADDON = HERE / "FlatCrossbar"
DIST = HERE / "dist"


def main():
    toc = (ADDON / "FlatCrossbar.toc").read_text(encoding="utf-8")
    version = re.search(r"^## Version:\s*(\S+)", toc, re.M)
    if not version:
        sys.exit("no ## Version line in the TOC")
    files = sorted(p for p in ADDON.rglob("*") if p.is_file())
    listed = {name for name in re.findall(r"^[^#\s].*$", toc, re.M)}
    missing = [name for name in listed if not (ADDON / name.replace("\\", "/")).is_file()]
    if missing:
        sys.exit("the TOC lists files that are missing: " + ", ".join(missing))

    DIST.mkdir(exist_ok=True)
    out = DIST / ("FlatCrossbar-%s.zip" % version.group(1))
    with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as z:
        for path in files:
            z.write(path, "FlatCrossbar/" + path.relative_to(ADDON).as_posix())
    print(out)
    for name in zipfile.ZipFile(out).namelist():
        print("  " + name)


main()
