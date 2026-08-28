#!/usr/bin/env python3
"""Create a deterministic, platform-neutral Future Engine Godot project zip."""

from pathlib import Path
from zipfile import ZIP_DEFLATED, ZipFile, ZipInfo

ROOT = Path(__file__).resolve().parents[1]
PROJECT = ROOT / "godot-project"
OUTPUT = ROOT / "dist" / "future-engine-desktop-addon-0.2.0.zip"
IGNORED_PARTS = {".godot", ".future_engine", ".future_engine_cache", ".future_engine_generated"}


def included(path: Path) -> bool:
    relative = path.relative_to(PROJECT)
    return (
        not any(part in IGNORED_PARTS for part in relative.parts)
        and not path.name.endswith("~")
        and not path.name.endswith(".import")
    )


OUTPUT.parent.mkdir(parents=True, exist_ok=True)
with ZipFile(OUTPUT, "w", ZIP_DEFLATED, compresslevel=9) as archive:
    for path in sorted(item for item in PROJECT.rglob("*") if item.is_file() and included(item)):
        relative = Path("future-engine-desktop") / path.relative_to(PROJECT)
        info = ZipInfo(str(relative).replace("\\", "/"), date_time=(2026, 8, 27, 0, 0, 0))
        info.compress_type = ZIP_DEFLATED
        info.external_attr = 0o644 << 16
        archive.writestr(info, path.read_bytes())

print(OUTPUT)
