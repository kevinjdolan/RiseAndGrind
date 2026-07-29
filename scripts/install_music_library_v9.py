#!/usr/bin/env python3
"""Atomically install the generated v9 loops into the app bundle as schema 5.

v4 shipped 500 Lyria loops of exactly 29.000 s each. v9 ships the ElevenLabs
loops that PyMusicLooper discovered, so two things change in the contract:

* Duration is a window, not a constant. Each loop is whatever length its own
  musical repeat turned out to be, anywhere in [20, 30) s, and nothing
  downstream may assume 29.000 s. (Only the imported-sound transcoder clamps to
  29 s; bundled CAFs are played straight from the bundle.)
* The library ships whatever the current plan version has mastered audio for
  on disk. plan_v3 holds all 320 songs, all mastered.

App track ids are renumbered to a contiguous tier_001..tier_NNN per tier,
because RiseAndGrindSettings.defaultSelectedSoundIDs generates that set
arithmetically and every bundled track must be selected by default. The plan id
each track came from is kept in `sourceId` so a song in the app can still be
traced back to its plan entry.

  scripts/install_music_library_v9.py            # stage, validate, install
  scripts/install_music_library_v9.py --check    # validate what is installed
"""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import shutil
import subprocess
import sys
from pathlib import Path
from typing import Any

PROJECT_ROOT = Path(__file__).resolve().parent.parent
PLAN_PATH = PROJECT_ROOT / "scratch_data" / "music_v9" / "plan_v3.json"
LOOP_DIRECTORY = PROJECT_ROOT / "scratch_data" / "music_v9" / "loops"
LIVE_AUDIO_DIRECTORY = PROJECT_ROOT / "RiseAndGrind" / "Resources" / "Sounds"
LIVE_MANIFEST_PATH = LIVE_AUDIO_DIRECTORY / "manifest.json"

TIERS = ("soothing", "relaxing", "motivating", "energizing", "abrasive")
SCHEMA_VERSION = 5
SONGS_PER_TIER = 64
PROVIDER = "elevenlabs"

APP_SAMPLE_RATE = 22_050
MINIMUM_LOOP_SECONDS = 20.0
MAXIMUM_LOOP_SECONDS = 30.0  # exclusive
MAXIMUM_APP_BYTES = 410_000


class InstallError(RuntimeError):
    """Raised when the library cannot be installed or fails validation."""


def probe_caf(path: Path) -> dict[str, Any]:
    """Read duration/rate/codec out of a CAF, and hold it to the v9 contract."""
    if not path.is_file() or path.stat().st_size == 0:
        raise InstallError(f"Missing or empty CAF: {path}")
    result = subprocess.run(["afinfo", str(path)], capture_output=True, text=True)
    if result.returncode != 0:
        raise InstallError(f"afinfo failed for {path}: {result.stderr.strip()[-200:]}")
    duration = re.search(r"estimated duration:\s+([\d.]+) sec", result.stdout)
    fmt = re.search(r"1 ch,\s+(\d+) Hz,\s+ima4", result.stdout)
    if not duration or not fmt:
        raise InstallError(f"{path.name} is not a mono IMA4 CAF")
    seconds = float(duration.group(1))
    rate = int(fmt.group(1))
    if rate != APP_SAMPLE_RATE:
        raise InstallError(f"{path.name} is {rate} Hz, expected {APP_SAMPLE_RATE}")
    if not (MINIMUM_LOOP_SECONDS <= seconds < MAXIMUM_LOOP_SECONDS):
        raise InstallError(
            f"{path.name} is {seconds:.3f}s, outside the v9 window "
            f"[{MINIMUM_LOOP_SECONDS}, {MAXIMUM_LOOP_SECONDS})"
        )
    size = path.stat().st_size
    if size > MAXIMUM_APP_BYTES:
        raise InstallError(f"{path.name} is {size} bytes, over {MAXIMUM_APP_BYTES}")
    return {"durationSeconds": round(seconds, 3), "sizeBytes": size}


def plan_index() -> dict[str, dict[str, Any]]:
    if not PLAN_PATH.is_file():
        raise InstallError(f"Missing plan: {PLAN_PATH}")
    return {song["id"]: song for song in json.loads(PLAN_PATH.read_text(encoding="utf-8"))}


def mastering_report(song_id: str) -> dict[str, Any]:
    """Loop provenance from the generator sidecar, if it is still around."""
    tier = song_id.split("_")[0]
    sidecar = (
        PROJECT_ROOT / "scratch_data" / "music_v9" / "audio" / PROVIDER / tier
        / f"{song_id}.json"
    )
    if not sidecar.is_file():
        return {}
    try:
        return json.loads(sidecar.read_text(encoding="utf-8")).get("mastering", {})
    except (OSError, json.JSONDecodeError):
        return {}


def build_catalog() -> list[dict[str, Any]]:
    """Pair every mastered loop with its plan entry and assign app ids."""
    plan = plan_index()
    catalog: list[dict[str, Any]] = []
    for tier in TIERS:
        available = sorted(
            path for path in LOOP_DIRECTORY.glob(f"{tier}_*_{PROVIDER}.caf")
        )
        if len(available) != SONGS_PER_TIER:
            raise InstallError(
                f"{tier}: found {len(available)} mastered loops, expected "
                f"{SONGS_PER_TIER}. Generate the missing ones before installing."
            )
        for index, loop_path in enumerate(available, start=1):
            source_id = loop_path.name.replace(f"_{PROVIDER}.caf", "")
            song = plan.get(source_id)
            if song is None:
                raise InstallError(f"{source_id} has audio but no plan_v2 entry")
            app_id = f"{tier}_{index:03d}"
            filename = f"{tier.capitalize()}{index:03d}.caf"
            report = mastering_report(source_id)
            catalog.append(
                {
                    "id": app_id,
                    "sourceId": source_id,
                    "intensityTier": tier,
                    "displayName": song["title"],
                    "artistName": song["artist"],
                    "genreName": song["genre"],
                    "performedLyrics": song["lyrics"],
                    "alarmFilename": filename,
                    "previewFilename": filename,
                    "defaultSelected": True,
                    "loopAuthored": True,
                    "bpm": song["bpm"],
                    "meter": song["meter"],
                    "bars": song["bars"],
                    "loopSeam": song["loopSeam"],
                    "loopScore": report.get("loopScore"),
                    "loopSeconds": report.get("loopSeconds"),
                    "_loopPath": loop_path,
                }
            )
    return catalog


def manifest_for(catalog: list[dict[str, Any]], durations: dict[str, float]) -> dict[str, Any]:
    tracks = []
    for entry in catalog:
        track = {key: value for key, value in entry.items() if key != "_loopPath"}
        track["durationSeconds"] = durations[entry["id"]]
        tracks.append(track)
    return {
        "schemaVersion": SCHEMA_VERSION,
        "trackCount": len(tracks),
        "tierCounts": {tier: SONGS_PER_TIER for tier in TIERS},
        "catalogVersion": "v9",
        "model": "elevenlabs-music",
        "mastering": "pymusiclooper discovery (scripts/master_loop_pml.py)",
        "loopWindowSeconds": [MINIMUM_LOOP_SECONDS, MAXIMUM_LOOP_SECONDS],
        "loopingPreview": True,
        "audioFormat": {
            "container": "caf",
            "codec": "ima4",
            "sampleRate": APP_SAMPLE_RATE,
            "channels": 1,
        },
        "tracks": tracks,
    }


def check_live_library() -> int:
    """Validate the installed library without touching any file."""
    if not LIVE_MANIFEST_PATH.is_file():
        print(f"No installed manifest at {LIVE_MANIFEST_PATH}")
        return 1
    manifest = json.loads(LIVE_MANIFEST_PATH.read_text(encoding="utf-8"))
    expected_total = SONGS_PER_TIER * len(TIERS)
    if manifest.get("schemaVersion") != SCHEMA_VERSION:
        print(f"Installed manifest is schema {manifest.get('schemaVersion')}, "
              f"expected {SCHEMA_VERSION}.")
        return 1
    tracks = manifest.get("tracks", [])
    if manifest.get("trackCount") != expected_total or len(tracks) != expected_total:
        print(f"Installed manifest has {len(tracks)} tracks, expected {expected_total}.")
        return 1
    if manifest.get("tierCounts") != {tier: SONGS_PER_TIER for tier in TIERS}:
        print("Installed tierCounts do not match.")
        return 1
    if not all(track.get("defaultSelected") for track in tracks):
        print("Every bundled track must be defaultSelected.")
        return 1
    expected_ids = {
        f"{tier}_{index:03d}" for tier in TIERS for index in range(1, SONGS_PER_TIER + 1)
    }
    if {track["id"] for track in tracks} != expected_ids:
        print("Installed track ids do not form the contiguous per-tier set.")
        return 1

    expected_files = set()
    for track in tracks:
        for key in ("alarmFilename", "previewFilename"):
            expected_files.add(track[key])
            probe_caf(LIVE_AUDIO_DIRECTORY / track[key])
    stray = sorted(
        path.name for path in LIVE_AUDIO_DIRECTORY.glob("*.caf")
        if path.name not in expected_files
    )
    if stray:
        print(f"Stray CAF files present ({len(stray)}): {', '.join(stray[:8])}")
        return 1
    total = sum((LIVE_AUDIO_DIRECTORY / t["alarmFilename"]).stat().st_size for t in tracks)
    lengths = [t["durationSeconds"] for t in tracks]
    print(
        f"Live library OK: {len(tracks)} schema-{SCHEMA_VERSION} loops "
        f"({total / 1024 / 1024:.1f} MiB), {min(lengths):.1f}-{max(lengths):.1f}s."
    )
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true")
    if parser.parse_args().check:
        return check_live_library()

    catalog = build_catalog()
    total = SONGS_PER_TIER * len(TIERS)
    print(f"Validating {len(catalog)} mastered loops before touching the app bundle…")
    durations: dict[str, float] = {}
    for entry in catalog:
        durations[entry["id"]] = probe_caf(entry["_loopPath"])["durationSeconds"]
    if len(catalog) != total:
        raise InstallError(f"Expected {total} loops, staged {len(catalog)}")

    manifest = manifest_for(catalog, durations)
    expected_files = {entry["alarmFilename"] for entry in catalog}

    LIVE_AUDIO_DIRECTORY.mkdir(parents=True, exist_ok=True)
    for entry in catalog:
        destination = LIVE_AUDIO_DIRECTORY / entry["alarmFilename"]
        temporary = destination.with_suffix(".caf.tmp")
        shutil.copy2(entry["_loopPath"], temporary)
        temporary.replace(destination)

    removed = []
    for existing in LIVE_AUDIO_DIRECTORY.glob("*.caf"):
        if existing.name not in expected_files:
            existing.unlink()
            removed.append(existing.name)

    temporary_manifest = LIVE_MANIFEST_PATH.with_suffix(".json.tmp")
    temporary_manifest.write_text(
        json.dumps(manifest, indent=2, ensure_ascii=False) + "\n", encoding="utf-8"
    )
    temporary_manifest.replace(LIVE_MANIFEST_PATH)

    for entry in catalog:
        probe_caf(LIVE_AUDIO_DIRECTORY / entry["alarmFilename"])

    installed_bytes = sum(
        (LIVE_AUDIO_DIRECTORY / entry["alarmFilename"]).stat().st_size for entry in catalog
    )
    lengths = sorted(durations.values())
    print(
        f"Installed {len(catalog)} CAF loops ({installed_bytes / 1024 / 1024:.1f} MiB), "
        f"{lengths[0]:.1f}-{lengths[-1]:.1f}s, removed {len(removed)} stale file(s), "
        f"wrote schema-{SCHEMA_VERSION} manifest."
    )
    digest = hashlib.sha256(LIVE_MANIFEST_PATH.read_bytes()).hexdigest()[:16]
    print(f"Manifest sha256: {digest}…")
    print("Run `xcodegen generate` so the bundled file list picks up the change.")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except InstallError as error:
        print(f"ERROR: {error}", file=sys.stderr)
        sys.exit(1)
