#!/usr/bin/env python3
"""Atomically install the fully validated staged v4 library into the app bundle.

Refuses to touch RiseAndGrind/Resources/Sounds until every staged CAF and the
staged manifest validate. Then swaps the complete library in one pass and
removes stale CAFs that are no longer part of the catalog.
"""

from __future__ import annotations

import argparse
import json
import shutil
import sys
from pathlib import Path

from generate_music_library_v4 import (
    STAGED_AUDIO_DIRECTORY,
    STAGED_MANIFEST_PATH,
    app_path,
    validate_app_audio,
)
from music_catalog_v4 import PROJECT_ROOT, TOTAL_SONGS, load_catalog_v4

LIVE_AUDIO_DIRECTORY = PROJECT_ROOT / "RiseAndGrind" / "Resources" / "Sounds"
LIVE_MANIFEST_PATH = LIVE_AUDIO_DIRECTORY / "manifest.json"


def check_live_library() -> int:
    """Validate the installed library against the catalog without touching files."""
    catalog = load_catalog_v4()
    manifest = json.loads(LIVE_MANIFEST_PATH.read_text(encoding="utf-8"))
    if manifest.get("schemaVersion") != 4 or manifest.get("trackCount") != TOTAL_SONGS:
        print("Live manifest is not a complete schema-4 catalog.")
        return 1
    manifest_ids = [track["id"] for track in manifest.get("tracks", [])]
    if manifest_ids != [track["id"] for track in catalog]:
        print("Live manifest track list does not match the authored catalog.")
        return 1
    for track in catalog:
        validate_app_audio(LIVE_AUDIO_DIRECTORY / f"{track['filename']}.caf")
    stray = sorted(
        path.name
        for path in LIVE_AUDIO_DIRECTORY.glob("*.caf")
        if path.name not in {f"{track['filename']}.caf" for track in catalog}
    )
    if stray:
        print(f"Stray CAF files present: {', '.join(stray[:10])}")
        return 1
    print(f"Live library OK: {TOTAL_SONGS} validated CAF loops match the manifest.")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true")
    if parser.parse_args().check:
        return check_live_library()
    catalog = load_catalog_v4()
    manifest = json.loads(STAGED_MANIFEST_PATH.read_text(encoding="utf-8"))
    if manifest.get("schemaVersion") != 4 or manifest.get("trackCount") != TOTAL_SONGS:
        print("Staged manifest is not a complete schema-4 catalog; aborting.")
        return 1
    if len(manifest.get("tracks", [])) != TOTAL_SONGS:
        print("Staged manifest track list is incomplete; aborting.")
        return 1

    print(f"Validating {TOTAL_SONGS} staged CAF loops before touching the app bundle…")
    for track in catalog:
        validate_app_audio(app_path(track))

    expected_files = {f"{track['filename']}.caf" for track in catalog}
    LIVE_AUDIO_DIRECTORY.mkdir(parents=True, exist_ok=True)
    installed = 0
    for track in catalog:
        source = app_path(track)
        destination = LIVE_AUDIO_DIRECTORY / source.name
        temporary = destination.with_suffix(".caf.tmp")
        shutil.copy2(source, temporary)
        temporary.replace(destination)
        installed += 1

    removed = []
    for existing in LIVE_AUDIO_DIRECTORY.glob("*.caf"):
        if existing.name not in expected_files:
            existing.unlink()
            removed.append(existing.name)

    temporary_manifest = LIVE_MANIFEST_PATH.with_suffix(".json.tmp")
    shutil.copy2(STAGED_MANIFEST_PATH, temporary_manifest)
    temporary_manifest.replace(LIVE_MANIFEST_PATH)

    for track in catalog:
        validate_app_audio(LIVE_AUDIO_DIRECTORY / f"{track['filename']}.caf")

    total_bytes = sum(
        (LIVE_AUDIO_DIRECTORY / f"{track['filename']}.caf").stat().st_size
        for track in catalog
    )
    print(
        f"Installed {installed} CAF loops ({total_bytes / 1024 / 1024:.1f} MiB), "
        f"removed {len(removed)} stale file(s), wrote schema-4 manifest."
    )
    if removed:
        print("Removed: " + ", ".join(sorted(removed)[:10]) + ("…" if len(removed) > 10 else ""))
    print(f"Staged copies remain in {STAGED_AUDIO_DIRECTORY} for provenance.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
