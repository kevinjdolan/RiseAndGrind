#!/usr/bin/env python3
"""Generate v6 plan audio on Lyria and ElevenLabs and master beat-aligned loops.

Reads a v6 plan JSON (50 songs with bpm/meter/bars/structure/loopSeam), asks
each provider for a ~30-32 s source built from the full musical spec (Lyria
prompts omit the artist name — Google's input filter rejects person-like
names), then masters each source with the beat-maintained v6 chain into
29.000 s IMA4 CAF loops. Everything lands under scratch_data/music_v6/audio;
nothing touches the app bundle.
"""

from __future__ import annotations

import argparse
import concurrent.futures
import hashlib
import json
import tempfile
from pathlib import Path
from typing import Any

import generate_elevenlabs_music_samples as elevenlabs_api
import generate_music_library_v4 as lyria_api
from generate_music_library_v4 import GenerationError, load_environment_key, log, probe_audio
from master_loop_v6 import master_loop_v6

PROJECT_ROOT = Path(__file__).resolve().parent.parent
CATALOG = "music_v6"
AUDIO_ROOT = PROJECT_ROOT / "scratch_data" / CATALOG / "audio"
LOOP_ROOT = PROJECT_ROOT / "scratch_data" / CATALOG / "loops"
MANIFEST_PATH = PROJECT_ROOT / "scratch_data" / CATALOG / "audio_manifest.json"
PLAN_VERSION = 6
PROVIDERS = ("lyria", "elevenlabs")
ELEVENLABS_LENGTH_MS = 32_000


def use_catalog(catalog: str, plan_version: int) -> None:
    """Point the output roots at a catalog directory under scratch_data."""
    global CATALOG, AUDIO_ROOT, LOOP_ROOT, MANIFEST_PATH, PLAN_VERSION
    CATALOG = catalog
    PLAN_VERSION = plan_version
    base = PROJECT_ROOT / "scratch_data" / catalog
    AUDIO_ROOT = base / "audio"
    LOOP_ROOT = base / "loops"
    MANIFEST_PATH = base / "audio_manifest.json"


def make_prompt(song: dict[str, Any]) -> str:
    """Build one generation prompt from the full plan entry (no artist name)."""
    structure = " / ".join(song["structure"])
    lyrics = "\n".join(f"- {line}" for line in song["lyrics"])
    return (
        f'Create an original high-fidelity 30-second song titled "{song["title"]}".\n'
        f'GENRE: {song["genre"]}.\n'
        f'KEY: {song["key"]}.\n'
        f'TEMPO: {song["bpm"]} BPM in {song["meter"]}; the piece is exactly '
        f'{song["bars"]} bars authored as a seamless loop.\n'
        f'VOCALIST: {song["vocalist"]}. Sing in English.\n'
        f'INSTRUMENTATION: {song["instrumentation"]}.\n'
        f'RHYTHM: {song["rhythm"]}.\n'
        f'STRUCTURE, timestamps from loop start: {structure}\n'
        f'LOOP SEAM: {song["loopSeam"]}\n'
        "Begin at full arrangement exactly on the downbeat with no intro, no fade-in, "
        "no count-off. Never fade out, never ritard, never end: the final bars are an "
        "instrumental turnaround that resolves directly into the opening downbeat so "
        "the clip repeats seamlessly. Do not imitate any existing artist, song, or "
        "recording. Keep the mix full-range and clean.\n"
        "Sing each short line once, clearly and in order. Do not add or repeat words:\n"
        f"{lyrics}"
    )


def paths_for(song: dict[str, Any], provider: str) -> tuple[Path, Path, Path]:
    tier = song["id"].split("_")[0]
    master = AUDIO_ROOT / provider / tier / f"{song['id']}.mp3"
    evidence = AUDIO_ROOT / provider / tier / f"{song['id']}.json"
    loop = LOOP_ROOT / f"{song['id']}_{provider}.caf"
    return master, evidence, loop


def outputs_are_valid(song: dict[str, Any], provider: str) -> bool:
    master, evidence, loop = paths_for(song, provider)
    try:
        if not master.is_file() or probe_audio(master)["duration"] < 29.5:
            return False
        record = json.loads(evidence.read_text(encoding="utf-8"))
        if record.get("planVersion") != PLAN_VERSION:
            return False
        return loop.is_file() and loop.stat().st_size > 0
    except (GenerationError, OSError, ValueError, json.JSONDecodeError):
        return False


def generate_one(
    song: dict[str, Any],
    provider: str,
    keys: dict[str, str],
    max_attempts: int,
    force: bool,
) -> None:
    master, evidence, loop = paths_for(song, provider)
    label = f"{provider} {song['id']} {song['title']}"
    if not force and outputs_are_valid(song, provider):
        log(f"SKIP  {label}")
        return
    master.parent.mkdir(parents=True, exist_ok=True)
    LOOP_ROOT.mkdir(parents=True, exist_ok=True)
    log(f"START {label}")
    prompt = make_prompt(song)
    with tempfile.TemporaryDirectory(prefix="rise-v6-audio-") as temporary:
        work = Path(temporary)
        pending_master = work / "master.mp3"
        for attempt in range(1, max_attempts + 1):
            if provider == "lyria":
                audio, record = lyria_api.request_audio(
                    prompt, keys["lyria"], max_attempts, label
                )
            else:
                original_length = elevenlabs_api.REQUESTED_LENGTH_MS
                elevenlabs_api.REQUESTED_LENGTH_MS = ELEVENLABS_LENGTH_MS
                try:
                    audio, record = elevenlabs_api.request_music(
                        prompt, keys["elevenlabs"], max_attempts, label
                    )
                finally:
                    elevenlabs_api.REQUESTED_LENGTH_MS = original_length
            pending_master.write_bytes(audio)
            duration = probe_audio(pending_master)["duration"]
            if duration >= 29.5:
                break
            if attempt == max_attempts:
                raise GenerationError(f"{label}: source stayed under 29.5s")
            log(f"RETRY {label}: source was {duration:.1f}s")
        pending_loop = work / loop.name
        try:
            report = master_loop_v6(
                pending_master, pending_loop, float(song["bpm"]),
                song["meter"], int(song["bars"]),
            )
        except GenerationError as error:
            log(f"NOTE  {label}: verified-tempo mastering failed ({error}); "
                "falling back to planned tempo")
            report = master_loop_v6(
                pending_master, pending_loop, float(song["bpm"]),
                song["meter"], int(song["bars"]), verify_tempo=False,
            )
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
        f"DONE  {label}: usedBpm {report['usedBpm']} "
        f"stretch {report['stretch']} conf {report['tempoConfidence']}"
    )


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("plan", type=Path)
    parser.add_argument("--force", action="store_true")
    parser.add_argument("--provider", choices=PROVIDERS)
    parser.add_argument("--only", action="append", default=[], metavar="ID")
    parser.add_argument("--workers", type=int, default=4)
    parser.add_argument("--max-attempts", type=int, default=4)
    parser.add_argument(
        "--catalog", default="music_v6",
        help="scratch_data catalog directory for audio/loops/manifest (default: music_v6)",
    )
    parser.add_argument(
        "--plan-version", type=int, default=6,
        help="planVersion stamped into each evidence record (default: 6)",
    )
    arguments = parser.parse_args()
    use_catalog(arguments.catalog, arguments.plan_version)

    songs = json.loads(arguments.plan.read_text(encoding="utf-8"))
    if arguments.only:
        songs = [s for s in songs if s["id"] in arguments.only]
    providers = [arguments.provider] if arguments.provider else list(PROVIDERS)
    keys = {
        "lyria": load_environment_key("GEMINI_API_KEY"),
        "elevenlabs": next(
            (
                key
                for name in ("ELEVEN_LABS_KEY", "ELEVENLABS_API_KEY", "ELEVEN_API_KEY")
                if (key := load_environment_key(name))
            ),
            "",
        ),
    }
    for provider in providers:
        if not keys[provider]:
            raise GenerationError(f"Missing API key for {provider}")

    jobs = [(song, provider) for provider in providers for song in songs]
    failures: list[str] = []
    with concurrent.futures.ThreadPoolExecutor(max_workers=arguments.workers) as executor:
        futures = {
            executor.submit(
                generate_one, song, provider, keys, arguments.max_attempts, arguments.force
            ): (song, provider)
            for song, provider in jobs
        }
        for future in concurrent.futures.as_completed(futures):
            song, provider = futures[future]
            try:
                future.result()
            except Exception as error:
                failures.append(f"{provider}/{song['id']}: {error}")
                log(f"FAIL  {provider}/{song['id']}: {error}")

    manifest = [
        {
            "id": song["id"],
            "displayName": song["title"],
            "intensityTier": song["id"].split("_")[0],
            "loops": {
                provider: str(paths_for(song, provider)[2].relative_to(PROJECT_ROOT))
                for provider in PROVIDERS
                if paths_for(song, provider)[2].is_file()
            },
        }
        for song in songs
    ]
    MANIFEST_PATH.write_text(
        json.dumps(manifest, indent=2, ensure_ascii=False) + "\n", encoding="utf-8"
    )
    if failures:
        log(f"v6 audio completed with {len(failures)} failure(s).")
        return 1
    log(f"SUCCESS: {len(jobs)} v6 sources generated and mastered under {AUDIO_ROOT}")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except GenerationError as error:
        log(f"ERROR: {error}")
        raise SystemExit(1) from error
