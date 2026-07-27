#!/usr/bin/env python3
"""Build listening previews for generated loop files: full loops played twice,
plus seam-only clips (the loop's last 5 seconds followed by its first 5
seconds), with a markdown index table of links.

Accepts a manifest JSON that is a list of entries shaped either like
  {"id","displayName","intensityTier","loops": {"lyria": path, "elevenlabs": path}}
or  {"id","displayName","intensityTier","provider","loop": path}
with paths relative to the repository root. CAF sources are decoded with
afconvert (ffmpeg cannot demux afconvert CAFs); everything else with ffmpeg.

Usage:
  build_music_previews.py MANIFEST.json --out tmp/previews [--seam-seconds 5]
"""

from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
import tempfile
from collections import defaultdict
from pathlib import Path

PROJECT_ROOT = Path(__file__).resolve().parent.parent
TIER_ORDER = ["soothing", "relaxing", "motivating", "energizing", "abrasive"]


def run(command: list[str]) -> None:
    result = subprocess.run(command, capture_output=True, text=True)
    if result.returncode != 0:
        raise RuntimeError(f"{command[0]} failed: {(result.stderr or '')[-400:]}")


def slug(name: str) -> str:
    return re.sub(r"[^A-Za-z0-9]+", "", name) or "song"


def to_wav(source: Path, destination: Path) -> None:
    if source.suffix.lower() == ".caf":
        run(["afconvert", str(source), str(destination), "-d", "LEI16", "-f", "WAVE"])
    else:
        run(["ffmpeg", "-hide_banner", "-loglevel", "error", "-y", "-i", str(source),
             str(destination)])


def encode(concat_list: Path, destination: Path) -> None:
    run(["ffmpeg", "-hide_banner", "-loglevel", "error", "-y", "-f", "concat",
         "-safe", "0", "-i", str(concat_list), "-c:a", "aac", "-b:a", "96k",
         str(destination)])


def normalize(entries: list[dict]) -> list[dict]:
    """Flatten both accepted manifest shapes into (entry, provider, path) rows."""
    rows = []
    for entry in entries:
        if "loops" in entry:
            for provider, path in sorted(entry["loops"].items()):
                rows.append({**entry, "provider": provider, "loop": path})
        else:
            rows.append(entry)
    return rows


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("manifest", type=Path)
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--seam-seconds", type=float, default=5.0)
    arguments = parser.parse_args()

    rows = normalize(json.loads(arguments.manifest.read_text(encoding="utf-8")))
    out_root = arguments.out if arguments.out.is_absolute() else PROJECT_ROOT / arguments.out
    providers = sorted({row["provider"] for row in rows})
    by_song: dict[tuple[str, str], dict] = defaultdict(dict)

    with tempfile.TemporaryDirectory(prefix="rise-previews-") as temporary:
        work = Path(temporary)
        for row in rows:
            source = PROJECT_ROOT / row["loop"]
            tier = row.get("intensityTier", "unknown")
            directory = out_root / tier
            directory.mkdir(parents=True, exist_ok=True)
            wav = work / (slug(row["id"]) + "_" + row["provider"] + ".wav")
            to_wav(source, wav)

            base = f"{slug(row['displayName'])}_{row['provider']}"
            double = directory / f"{base}_x2.m4a"
            listing = work / "pair.txt"
            listing.write_text(f"file '{wav}'\nfile '{wav}'\n")
            encode(listing, double)

            seam_seconds = arguments.seam_seconds
            tail = work / f"{base}_tail.wav"
            head = work / f"{base}_head.wav"
            run(["ffmpeg", "-hide_banner", "-loglevel", "error", "-y", "-sseof",
                 f"-{seam_seconds}", "-i", str(wav), str(tail)])
            run(["ffmpeg", "-hide_banner", "-loglevel", "error", "-y", "-i", str(wav),
                 "-t", f"{seam_seconds}", str(head)])
            seam = directory / f"{base}_seam.m4a"
            listing.write_text(f"file '{tail}'\nfile '{head}'\n")
            encode(listing, seam)

            by_song[(tier, row["displayName"])][row["provider"]] = (double, seam)

    lines = [
        "# Loop previews",
        "",
        f"`_x2` = full loop played twice (the repeat boundary is the seam). "
        f"`_seam` = last {arguments.seam_seconds:.0f} s + first "
        f"{arguments.seam_seconds:.0f} s only.",
        "",
    ]
    for tier in TIER_ORDER + sorted(
        {t for t, _ in by_song} - set(TIER_ORDER)
    ):
        songs = {name: p for (t, name), p in by_song.items() if t == tier}
        if not songs:
            continue
        lines.append(f"## {tier.capitalize()}")
        lines.append("")
        header = "| Song | " + " | ".join(
            f"{p} ×2 | {p} seam" for p in providers
        ) + " |"
        lines.append(header)
        lines.append("|" + "---|" * (1 + 2 * len(providers)))
        for name in sorted(songs):
            cells = [name]
            for provider in providers:
                pair = songs[name].get(provider)
                if pair:
                    double, seam = pair
                    cells.append(f"[play]({double.relative_to(out_root)})")
                    cells.append(f"[seam]({seam.relative_to(out_root)})")
                else:
                    cells.extend(["—", "—"])
            lines.append("| " + " | ".join(cells) + " |")
        lines.append("")
    index = out_root / "index.md"
    index.write_text("\n".join(lines) + "\n", encoding="utf-8")
    print(f"Wrote {len(rows)} preview pairs and {index}")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except RuntimeError as error:
        print(f"ERROR: {error}", file=sys.stderr)
        sys.exit(1)
