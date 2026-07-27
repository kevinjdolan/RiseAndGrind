#!/usr/bin/env python3
"""Assemble the diversity/profanity-rewritten v5 catalog from workflow tier files.

Validates against the v5 vulgarity policy, checks that every locked field
(title, artist, vocalist gender, genre, region) is unchanged from v4, and
writes music_catalog_v5.json plus its reviewer YAML. The v4 catalog and the
installed library stay untouched.
"""

from __future__ import annotations

import argparse
import json
import sys
from collections import Counter
from pathlib import Path
from typing import Any

from build_catalog_v4 import emit_yaml
from music_catalog_v4 import (
    CATALOG_V4_PATH,
    PROJECT_ROOT,
    TIER_PROFILES_V4,
    V5_VULGARITY_LIMITS,
    validate_catalog_v4,
    vulgarity_score,
)

CATALOG_V5_PATH = PROJECT_ROOT / "scratch_data" / "music_catalog_v5.json"
YAML_V5_PATH = PROJECT_ROOT / "scratch_data" / "music_catalog_v5.yaml"

LOCKED_KEYS = (
    "id",
    "number",
    "intensityTier",
    "intensityName",
    "displayName",
    "filename",
    "artistName",
    "vocalistGender",
    "genreName",
    "region",
)


def assemble(directory: Path) -> list[dict[str, Any]]:
    """Merge the 20 rewritten tier files into the ordered 500-track catalog."""
    catalog: list[dict[str, Any]] = []
    for tier in TIER_PROFILES_V4:
        for part in range(4):
            path = directory / f"{tier.identifier}_part{part}.json"
            songs = json.loads(path.read_text(encoding="utf-8"))
            if len(songs) != 25:
                raise RuntimeError(f"{path} holds {len(songs)} songs, expected 25")
            for song in songs:
                song = dict(song)
                song.pop("diversityFlags", None)
                song.setdefault("defaultSelected", True)
                # The split files omit the derivable identity fields; restore them.
                song["intensityTier"] = tier.identifier
                song["intensityName"] = tier.display_name
                song["filename"] = f"{tier.display_name}{song['number']:03d}"
                catalog.append(song)
    catalog.sort(
        key=lambda t: (
            [x.identifier for x in TIER_PROFILES_V4].index(t["intensityTier"]),
            t["number"],
        )
    )
    return catalog


def check_locked_fields(catalog: list[dict[str, Any]]) -> list[str]:
    """Require every locked field to match the v4 catalog exactly."""
    v4 = {t["id"]: t for t in json.loads(CATALOG_V4_PATH.read_text(encoding="utf-8"))}
    problems: list[str] = []
    for track in catalog:
        old = v4.get(track["id"])
        if old is None:
            problems.append(f"{track['id']}: not present in v4")
            continue
        for key in LOCKED_KEYS:
            if track.get(key) != old.get(key):
                problems.append(
                    f"{track['id']}: locked field {key} changed "
                    f"({old.get(key)!r} -> {track.get(key)!r})"
                )
    return problems


def report(catalog: list[dict[str, Any]]) -> None:
    """Print vulgarity distribution and diversity stats per tier."""
    for tier in TIER_PROFILES_V4:
        tracks = [t for t in catalog if t["intensityTier"] == tier.identifier]
        scores = Counter(vulgarity_score(t) for t in tracks)
        openers = Counter(t["performedLyrics"][0].split()[0].lower().strip(",") for t in tracks)
        dup_openers = {w: n for w, n in openers.items() if n > 2}
        print(
            f"{tier.display_name:>10}: vulgarity {dict(sorted(scores.items()))} "
            f"| dup openers {dup_openers or 'none'}"
        )


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("directory", type=Path)
    parser.add_argument("--report-only", action="store_true")
    arguments = parser.parse_args()

    catalog = assemble(arguments.directory)
    problems = validate_catalog_v4(catalog, vulgarity_limits=V5_VULGARITY_LIMITS)
    problems += check_locked_fields(catalog)
    if problems:
        print(f"VALIDATION: {len(problems)} problem(s)")
        for problem in problems[:60]:
            print(f"- {problem}")
        if not arguments.report_only:
            return 1
    report(catalog)
    if arguments.report_only:
        return 0
    CATALOG_V5_PATH.write_text(
        json.dumps(catalog, indent=2, ensure_ascii=False) + "\n", encoding="utf-8"
    )
    YAML_V5_PATH.write_text(emit_yaml(catalog) + "\n", encoding="utf-8")
    print(f"Wrote {CATALOG_V5_PATH}")
    print(f"Wrote {YAML_V5_PATH}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
