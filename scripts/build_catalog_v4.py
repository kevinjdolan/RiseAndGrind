#!/usr/bin/env python3
"""Assemble the authored v4 catalog from workflow batch files into JSON and YAML."""

from __future__ import annotations

import argparse
import json
import sys
from collections import Counter
from pathlib import Path
from typing import Any

from music_catalog_v4 import (
    CATALOG_V4_PATH,
    PROJECT_ROOT,
    TIER_PROFILES_V4,
    validate_catalog_v4,
)

YAML_PATH = PROJECT_ROOT / "scratch_data" / "music_catalog_v4.yaml"

BATCH_KEYS = {
    "slot",
    "title",
    "artist",
    "vocalistGender",
    "vocalistStyle",
    "language",
    "region",
    "genreName",
    "genreDescription",
    "bpm",
    "energyDirection",
    "comicPremise",
    "lyrics",
    "translation",
}


def yaml_quote(value: str) -> str:
    """Return a double-quoted YAML scalar with full escaping."""
    escaped = (
        value.replace("\\", "\\\\")
        .replace('"', '\\"')
        .replace("\n", "\\n")
        .replace("\t", "\\t")
    )
    return f'"{escaped}"'


def emit_yaml(catalog: list[dict[str, Any]]) -> str:
    """Emit the catalog as reviewer-friendly YAML grouped by tier."""
    lines: list[str] = [
        "# Rise & Grind alarm music catalog v4",
        "# 500 original 29-second looping songs: 100 per intensity tier.",
        "# Sarcastic hustle-culture satire, 50/50 female/male vocalists per tier,",
        "# international genre spread. Generated masters retain full provenance.",
        "",
    ]
    for tier in TIER_PROFILES_V4:
        tier_tracks = [
            track for track in catalog if track["intensityTier"] == tier.identifier
        ]
        lines.append(f"{tier.identifier}:")
        for track in tier_tracks:
            lines.append(f"  - id: {track['id']}")
            lines.append(f"    title: {yaml_quote(track['displayName'])}")
            lines.append(f"    artist: {yaml_quote(track['artistName'])}")
            vocalist = f"{track['vocalistGender']} — {track['vocalistStyle']}"
            lines.append(f"    vocalist: {yaml_quote(vocalist)}")
            lines.append(f"    language: {yaml_quote(track['language'])}")
            lines.append(f"    region: {yaml_quote(track['region'])}")
            lines.append(f"    genre: {yaml_quote(track['genreName'])}")
            musicality = (
                f"{track['genreDescription']} ({track['bpm']} BPM; "
                f"{track['energyDirection']})"
            )
            lines.append(f"    musicality: {yaml_quote(musicality)}")
            lines.append(f"    premise: {yaml_quote(track['comicPremise'])}")
            lines.append("    lyrics:")
            for line in track["performedLyrics"]:
                lines.append(f"      - {yaml_quote(line)}")
            if track.get("translation"):
                lines.append(f"    translation: {yaml_quote(track['translation'])}")
        lines.append("")
    return "\n".join(lines)


def assemble(batch_directory: Path) -> list[dict[str, Any]]:
    """Merge the 20 workflow batch files into the ordered 500-track catalog."""
    catalog: list[dict[str, Any]] = []
    for tier in TIER_PROFILES_V4:
        number = 0
        for batch_index in range(4):
            batch_path = batch_directory / f"{tier.identifier}_batch{batch_index}.json"
            songs = json.loads(batch_path.read_text(encoding="utf-8"))
            if len(songs) != 25:
                raise RuntimeError(f"{batch_path} holds {len(songs)} songs, expected 25")
            for song in sorted(songs, key=lambda item: item["slot"]):
                unknown = set(song) - BATCH_KEYS
                missing = BATCH_KEYS - set(song)
                if unknown or missing:
                    raise RuntimeError(
                        f"{batch_path} slot {song.get('slot')}: "
                        f"unknown keys {sorted(unknown)}, missing {sorted(missing)}"
                    )
                number += 1
                catalog.append(
                    {
                        "number": number,
                        "id": f"{tier.identifier}_{number:03d}",
                        "intensityTier": tier.identifier,
                        "intensityName": tier.display_name,
                        "displayName": str(song["title"]).strip(),
                        "filename": f"{tier.display_name}{number:03d}",
                        "artistName": str(song["artist"]).strip(),
                        "vocalistGender": song["vocalistGender"],
                        "vocalistStyle": str(song["vocalistStyle"]).strip(),
                        "language": str(song["language"]).strip(),
                        "region": str(song["region"]).strip(),
                        "genreName": str(song["genreName"]).strip(),
                        "genreDescription": str(song["genreDescription"]).strip(),
                        "bpm": song["bpm"],
                        "energyDirection": str(song["energyDirection"]).strip(),
                        "comicPremise": str(song["comicPremise"]).strip(),
                        "performedLyrics": [
                            str(line).strip() for line in song["lyrics"]
                        ],
                        "translation": (
                            str(song["translation"]).strip()
                            if song.get("translation")
                            else None
                        ),
                        "defaultSelected": True,
                    }
                )
    return catalog


def print_stats(catalog: list[dict[str, Any]]) -> None:
    """Print distribution statistics for review."""
    for tier in TIER_PROFILES_V4:
        tier_tracks = [
            track for track in catalog if track["intensityTier"] == tier.identifier
        ]
        genders = Counter(track["vocalistGender"] for track in tier_tracks)
        genres = len({track["genreName"].lower() for track in tier_tracks})
        non_english = sum(
            1 for track in tier_tracks if track["language"].lower() != "english"
        )
        print(
            f"{tier.display_name:>10}: {len(tier_tracks)} songs, "
            f"{genders['female']}F/{genders['male']}M, {genres} genres, "
            f"{non_english} non-English/bilingual"
        )
    print(
        f"{'Total':>10}: {len(catalog)} songs, "
        f"{len({t['genreName'].lower() for t in catalog})} distinct genres, "
        f"{len({t['language'].lower() for t in catalog})} languages, "
        f"{len({t['region'].lower() for t in catalog})} regions"
    )


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("batch_directory", type=Path)
    parser.add_argument("--report-only", action="store_true")
    arguments = parser.parse_args()

    catalog = assemble(arguments.batch_directory)
    problems = validate_catalog_v4(catalog)
    if problems:
        print(f"VALIDATION: {len(problems)} problem(s)")
        for problem in problems:
            print(f"- {problem}")
        if not arguments.report_only:
            return 1
    if arguments.report_only:
        print_stats(catalog)
        return 0

    CATALOG_V4_PATH.parent.mkdir(parents=True, exist_ok=True)
    CATALOG_V4_PATH.write_text(
        json.dumps(catalog, indent=2, ensure_ascii=False) + "\n", encoding="utf-8"
    )
    YAML_PATH.write_text(emit_yaml(catalog) + "\n", encoding="utf-8")
    print(f"Wrote {CATALOG_V4_PATH}")
    print(f"Wrote {YAML_PATH}")
    print_stats(catalog)
    return 0


if __name__ == "__main__":
    sys.exit(main())
