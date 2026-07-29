#!/usr/bin/env python3
"""Generate v9 plan audio on ElevenLabs and master it with PyMusicLooper.

Two deliberate departures from generate_v6/v7_audio.py:

* ElevenLabs only. v9 drops the Lyria half of the comparison.
* Sources are requested LONG (~45 s) even though the loop ships at 20-30 s.
  PyMusicLooper can only find a seam where the music actually repeats, so it
  needs material to search; the v6-v8 data showed every high-scoring long loop
  came from a 50-60 s source, while 30 s sources forced short or poor loops.

Mastering runs out-of-process under .venvs/pml (numpy/librosa/soundfile), so
this script itself stays stdlib-only like the rest of scripts/.

  scripts/generate_v9_audio.py scratch_data/music_v9/plan_v2.json [--only ID]
"""

from __future__ import annotations

import argparse
import concurrent.futures
import hashlib
import json
import subprocess
import sys
import tempfile
from pathlib import Path
from typing import Any

sys.path.insert(0, str(Path(__file__).resolve().parent))
import generate_elevenlabs_music_samples as elevenlabs_api  # noqa: E402
from generate_music_library_v4 import (  # noqa: E402
    GenerationError,
    load_environment_key,
    log,
    probe_audio,
)

PROJECT_ROOT = Path(__file__).resolve().parent.parent
BASE = PROJECT_ROOT / "scratch_data" / "music_v9"
AUDIO_ROOT = BASE / "audio"
LOOP_ROOT = BASE / "loops"
MANIFEST_PATH = BASE / "audio_manifest.json"
MASTERER = PROJECT_ROOT / "scripts" / "master_loop_pml.py"
VENV_PYTHON = PROJECT_ROOT / ".venvs" / "pml" / "bin" / "python"

PROVIDER = "elevenlabs"
PLAN_VERSION = 9
ELEVENLABS_LENGTH_MS = 45_000
MINIMUM_SOURCE_SECONDS = 38.0


def make_prompt(song: dict[str, Any]) -> str:
    """Build one generation prompt from the full plan entry.

    The structure timestamps describe one pass of the loop; the source is asked
    to run longer so the mastering pass has room to find the repeat.
    """
    structure = " / ".join(song["structure"])
    lyrics = "\n".join(f"- {line}" for line in song["lyrics"])
    return (
        f'Create an original high-fidelity song titled "{song["title"]}".\n'
        f'GENRE: {song["genre"]}.\n'
        f'KEY: {song["key"]}.\n'
        f'TEMPO: {song["bpm"]} BPM in {song["meter"]}; the musical idea is '
        f'{song["bars"]} bars long and repeats.\n'
        f'VOCALIST: {song["vocalist"]}. Sing in English.\n'
        f'INSTRUMENTATION: {song["instrumentation"]}.\n'
        f'RHYTHM: {song["rhythm"]}.\n'
        f'STRUCTURE, timestamps from the start of one pass: {structure}\n'
        f'LOOP SEAM: {song["loopSeam"]}\n'
        "Begin at full arrangement exactly on the downbeat with no intro, no fade-in, "
        "no count-off. Hold one steady tempo throughout — never ritard, never fade "
        "out, never end. Play the idea through and then repeat it, returning to the "
        "opening downbeat with the arrangement unchanged, so the same passage recurs "
        "identically later in the take. Do not imitate any existing artist, song, or "
        "recording. Keep the mix full-range and clean.\n"
        "Sing each short line once, clearly and in order, on every pass. Do not add "
        "or repeat words:\n"
        f"{lyrics}"
    )


def paths_for(song: dict[str, Any]) -> tuple[Path, Path, Path]:
    tier = str(song["id"]).split("_")[0]
    master = AUDIO_ROOT / PROVIDER / tier / f"{song['id']}.mp3"
    evidence = AUDIO_ROOT / PROVIDER / tier / f"{song['id']}.json"
    loop = LOOP_ROOT / f"{song['id']}_{PROVIDER}.caf"
    return master, evidence, loop


def outputs_are_valid(song: dict[str, Any]) -> bool:
    master, evidence, loop = paths_for(song)
    try:
        if not master.is_file() or probe_audio(master)["duration"] < MINIMUM_SOURCE_SECONDS:
            return False
        record = json.loads(evidence.read_text(encoding="utf-8"))
        if record.get("planVersion") != PLAN_VERSION:
            return False
        return loop.is_file() and loop.stat().st_size > 0
    except (GenerationError, OSError, ValueError, json.JSONDecodeError):
        return False


def master_with_pml(source: Path, destination: Path) -> dict[str, Any]:
    """Run the PyMusicLooper masterer out-of-process under its own venv."""
    if not VENV_PYTHON.is_file():
        raise GenerationError(
            f"Missing mastering venv at {VENV_PYTHON}; create it with "
            "`uv venv --python 3.12 .venvs/pml && "
            "uv pip install --python .venvs/pml/bin/python pymusiclooper`"
        )
    result = subprocess.run(
        [str(VENV_PYTHON), str(MASTERER), str(source), str(destination)],
        capture_output=True, text=True,
    )
    if result.returncode != 0:
        raise GenerationError(
            f"mastering failed: {(result.stderr or result.stdout or '').strip()[-300:]}"
        )
    try:
        return json.loads(result.stdout)
    except json.JSONDecodeError as error:
        raise GenerationError(f"mastering returned non-JSON: {result.stdout[:200]}") from error


def generate_one(
    song: dict[str, Any], key: str, max_attempts: int, force: bool
) -> None:
    master, evidence, loop = paths_for(song)
    label = f"{song['id']} {song['title']}"
    if not force and outputs_are_valid(song):
        log(f"SKIP  {label}")
        return
    master.parent.mkdir(parents=True, exist_ok=True)
    LOOP_ROOT.mkdir(parents=True, exist_ok=True)
    log(f"START {label}")
    prompt = make_prompt(song)

    with tempfile.TemporaryDirectory(prefix="rise-v9-audio-") as temporary:
        work = Path(temporary)
        pending_master = work / "master.mp3"
        audio: bytes = b""
        record: dict[str, Any] = {}
        original_length = elevenlabs_api.REQUESTED_LENGTH_MS
        elevenlabs_api.REQUESTED_LENGTH_MS = ELEVENLABS_LENGTH_MS
        try:
            for attempt in range(1, max_attempts + 1):
                audio, record = elevenlabs_api.request_music(
                    prompt, key, max_attempts, label
                )
                pending_master.write_bytes(audio)
                duration = probe_audio(pending_master)["duration"]
                if duration >= MINIMUM_SOURCE_SECONDS:
                    break
                if attempt == max_attempts:
                    raise GenerationError(
                        f"{label}: source stayed under {MINIMUM_SOURCE_SECONDS}s"
                    )
                log(f"RETRY {label}: source was {duration:.1f}s")
        finally:
            elevenlabs_api.REQUESTED_LENGTH_MS = original_length

        pending_loop = work / loop.name
        report = master_with_pml(pending_master, pending_loop)
        record.update(
            {
                "trackID": song["id"],
                "planVersion": PLAN_VERSION,
                "prompt": prompt,
                "mastering": report,
                "sourceSha256": hashlib.sha256(audio).hexdigest(),
            }
        )
        pending_master.replace(master)
        evidence.write_text(json.dumps(record, indent=2) + "\n", encoding="utf-8")
        pending_loop.replace(loop)

    log(
        f"DONE  {label}: loop {report['loopSeconds']}s "
        f"score {report['loopScore']} rung {report['ladderRung']}"
    )


def write_manifest(songs: list[dict[str, Any]]) -> None:
    manifest = [
        {
            "id": song["id"],
            "displayName": song["title"],
            "intensityTier": str(song["id"]).split("_")[0],
            "loops": {PROVIDER: str(paths_for(song)[2].relative_to(PROJECT_ROOT))},
        }
        for song in songs
        if paths_for(song)[2].is_file()
    ]
    MANIFEST_PATH.parent.mkdir(parents=True, exist_ok=True)
    MANIFEST_PATH.write_text(
        json.dumps(manifest, indent=2, ensure_ascii=False) + "\n", encoding="utf-8"
    )


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("plan", type=Path)
    parser.add_argument("--force", action="store_true")
    parser.add_argument("--only", action="append", default=[], metavar="ID")
    parser.add_argument("--tier", action="append", default=[], metavar="TIER")
    parser.add_argument("--limit", type=int, default=None)
    parser.add_argument("--workers", type=int, default=4)
    parser.add_argument("--max-attempts", type=int, default=4)
    arguments = parser.parse_args()

    songs = json.loads(arguments.plan.read_text(encoding="utf-8"))
    if arguments.only:
        songs = [s for s in songs if s["id"] in arguments.only]
    if arguments.tier:
        songs = [s for s in songs if str(s["id"]).split("_")[0] in arguments.tier]
    if arguments.limit:
        songs = songs[: arguments.limit]

    key = next(
        (
            k
            for name in ("ELEVEN_LABS_KEY", "ELEVENLABS_API_KEY", "ELEVEN_API_KEY")
            if (k := load_environment_key(name))
        ),
        "",
    )
    if not key:
        raise GenerationError("Missing ElevenLabs API key")

    failures: list[str] = []
    with concurrent.futures.ThreadPoolExecutor(max_workers=arguments.workers) as executor:
        futures = {
            executor.submit(
                generate_one, song, key, arguments.max_attempts, arguments.force
            ): song
            for song in songs
        }
        for future in concurrent.futures.as_completed(futures):
            song = futures[future]
            try:
                future.result()
            except Exception as error:
                failures.append(f"{song['id']}: {error}")
                log(f"FAIL  {song['id']}: {error}")

    all_songs = json.loads(arguments.plan.read_text(encoding="utf-8"))
    write_manifest(all_songs)
    if failures:
        log(f"v9 audio completed with {len(failures)} failure(s).")
        return 1
    log(f"SUCCESS: {len(songs)} v9 sources generated and mastered under {AUDIO_ROOT}")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except GenerationError as error:
        log(f"ERROR: {error}")
        raise SystemExit(1) from error
