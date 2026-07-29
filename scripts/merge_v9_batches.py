#!/usr/bin/env python3
"""Merge authored v9 song batches into per-tier plan files.

Authoring is fanned out across agents, one batch of 16 songs each, writing
scratch_data/music_v9/authored/{tier}_batch{N}.json. This collects those into
scratch_data/music_v9/{plan_version}/{tier}.json in id order and reports what
is still missing, so build_plan_v9.py can validate the assembled set.

  scripts/merge_v9_batches.py [--plan-version plan_v1] [--report]
"""

from __future__ import annotations

import argparse
import json
import re
from collections import Counter
from pathlib import Path

PROJECT_ROOT = Path(__file__).resolve().parent.parent
BASE = PROJECT_ROOT / "scratch_data" / "music_v9"
TIERS = ["soothing", "relaxing", "motivating", "energizing", "abrasive"]
SONGS_PER_TIER = 64
BATCHES = (1, 2, 3, 4)


def sort_key(song: dict) -> tuple[str, int]:
    identifier = str(song.get("id", ""))
    match = re.match(r"([a-z]+)_(\d+)$", identifier)
    return (match.group(1), int(match.group(2))) if match else (identifier, 0)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--plan-version", default="plan_v1")
    parser.add_argument("--report", action="store_true",
                        help="report coverage without writing tier files")
    arguments = parser.parse_args()

    authored = BASE / "authored"
    out_dir = BASE / arguments.plan_version
    total = 0
    all_songs: list[dict] = []

    for tier in TIERS:
        songs: list[dict] = []
        missing_batches = []
        for batch in BATCHES:
            path = authored / f"{tier}_batch{batch}.json"
            if not path.is_file():
                missing_batches.append(batch)
                continue
            try:
                entries = json.loads(path.read_text(encoding="utf-8"))
            except json.JSONDecodeError as error:
                print(f"{tier} batch{batch}: INVALID JSON — {error}")
                continue
            if not isinstance(entries, list):
                print(f"{tier} batch{batch}: expected a JSON array")
                continue
            songs.extend(entries)

        songs.sort(key=sort_key)
        seen_ids = Counter(str(s.get("id")) for s in songs)
        duplicates = [i for i, c in seen_ids.items() if c > 1]
        expected = {f"{tier}_{n:03d}" for n in range(1, SONGS_PER_TIER + 1)}
        missing_ids = sorted(expected - set(seen_ids))

        status = f"{tier}: {len(songs)}/{SONGS_PER_TIER}"
        if missing_batches:
            status += f"  missing batches {missing_batches}"
        if duplicates:
            status += f"  DUPLICATE ids {duplicates[:5]}"
        if missing_ids:
            status += f"  missing ids {missing_ids[:5]}{'...' if len(missing_ids) > 5 else ''}"
        print(status)

        total += len(songs)
        all_songs.extend(songs)
        if songs and not arguments.report:
            out_dir.mkdir(parents=True, exist_ok=True)
            (out_dir / f"{tier}.json").write_text(
                json.dumps(songs, indent=2, ensure_ascii=False) + "\n", encoding="utf-8"
            )

    for field in ("title", "artist"):
        counts = Counter(str(s.get(field, "")).strip().lower() for s in all_songs)
        clashes = [v for v, c in counts.items() if c > 1 and v]
        if clashes:
            print(f"GLOBAL duplicate {field}: {len(clashes)} — {clashes[:8]}")

    print(f"total {total}/{len(TIERS) * SONGS_PER_TIER}")
    if not arguments.report and total:
        print(f"wrote tier files under {out_dir}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
