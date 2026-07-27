#!/usr/bin/env python3
"""Generate a 50-song comparison sample (10 per tier) with the ElevenLabs Music API.

Outputs stay entirely inside scratch_data/ElevenLabsMusicSamples — full-fidelity
masters, generation evidence, and mastered 29-second loop CAFs for audition —
so the app bundle is untouched. Selection is deterministic: per tier, greedily
pick genre-distinct songs alternating female/male vocalists (5F/5M).
"""

from __future__ import annotations

import argparse
import concurrent.futures
import hashlib
import json
import random
import tempfile
import time
import urllib.error
import urllib.request
from pathlib import Path
from typing import Any

from generate_music_library_v4 import (
    DEFAULT_ENV_FILE,
    GenerationError,
    load_environment_key,
    log,
    master_loop,
    probe_audio,
    validate_app_audio,
)
from music_catalog_v4 import PROJECT_ROOT, TIER_PROFILES_V4, load_catalog_v4

MUSIC_ENDPOINT = "https://api.elevenlabs.io/v1/music?output_format=mp3_44100_128"
PREFERRED_MODEL = "music_v2"
FALLBACK_MODEL = "music_v1"
REQUESTED_LENGTH_MS = 30_000
SAMPLES_PER_TIER = 10

SAMPLE_DIRECTORY = PROJECT_ROOT / "scratch_data" / "ElevenLabsMusicSamples"
LOOP_DIRECTORY = SAMPLE_DIRECTORY / "loops"
SAMPLE_MANIFEST_PATH = SAMPLE_DIRECTORY / "samples_manifest.json"


def select_samples(catalog: tuple[dict[str, Any], ...]) -> list[dict[str, Any]]:
    """Deterministically pick 10 genre-diverse songs per tier, 5 female / 5 male."""
    selected: list[dict[str, Any]] = []
    for tier in TIER_PROFILES_V4:
        tier_tracks = [
            track for track in catalog if track["intensityTier"] == tier.identifier
        ]
        picks: list[dict[str, Any]] = []
        seen_genres: set[str] = set()
        wanted = "female"
        for relax_genre in (False, True):
            for track in tier_tracks:
                if len(picks) == SAMPLES_PER_TIER:
                    break
                if track in picks or track["vocalistGender"] != wanted:
                    continue
                genre = track["genreName"].lower()
                if not relax_genre and genre in seen_genres:
                    continue
                picks.append(track)
                seen_genres.add(genre)
                wanted = "male" if wanted == "female" else "female"
            if len(picks) == SAMPLES_PER_TIER:
                break
        if len(picks) != SAMPLES_PER_TIER:
            raise GenerationError(
                f"Could only select {len(picks)} samples for {tier.identifier}"
            )
        selected.extend(picks)
    return selected


def make_prompt(track: dict[str, Any]) -> str:
    """Build one ElevenLabs Music prompt mirroring the Lyria brief."""
    lyrics = "\n".join(f"- {line}" for line in track["performedLyrics"])
    language = track["language"]
    language_line = (
        "Sing in English."
        if language.lower() == "english"
        else (
            f"Language: {language}. Sing each lyric line exactly as written, "
            "keeping non-English lines in their original language."
        )
    )
    return (
        f'An original 30-second song titled "{track["displayName"]}" in the style of a '
        f'fictional act called "{track["artistName"]}". '
        f'Genre: {track["genreName"]}; {track["genreDescription"]}. '
        f'{track["vocalistGender"].capitalize()} lead vocal; {track["vocalistStyle"]}. '
        f'Tempo: {track["bpm"]} BPM. Energy: {track["energyDirection"]}. '
        f"{language_line} "
        "Author it as a continuous loop: begin immediately, never fade or stop, and "
        "return by the final seconds to the opening groove and instrumentation. "
        "Sing exactly these four short lines once each, in order, adding no other "
        f"words:\n{lyrics}"
    )


def request_music(
    prompt: str,
    api_key: str,
    max_attempts: int,
    label: str,
) -> tuple[bytes, dict[str, Any]]:
    """Request one clip, preferring music_v2 and falling back to music_v1."""
    model = PREFERRED_MODEL
    for attempt in range(1, max_attempts + 1):
        body = json.dumps(
            {
                "model_id": model,
                "prompt": prompt,
                "music_length_ms": REQUESTED_LENGTH_MS,
            }
        ).encode("utf-8")
        request = urllib.request.Request(
            MUSIC_ENDPOINT,
            data=body,
            method="POST",
            headers={
                "Content-Type": "application/json",
                "xi-api-key": api_key,
                "User-Agent": "RiseAndGrind-MusicSamples/1.0",
            },
        )
        try:
            with urllib.request.urlopen(request, timeout=600) as response:
                audio = response.read()
                if not audio:
                    raise GenerationError("Empty ElevenLabs response body")
                return audio, {
                    "endpoint": MUSIC_ENDPOINT,
                    "model": model,
                    "requestedLengthMs": REQUESTED_LENGTH_MS,
                    "audioByteCount": len(audio),
                }
        except urllib.error.HTTPError as error:
            detail = error.read().decode("utf-8", errors="replace")[:500]
            if (
                model == PREFERRED_MODEL
                and error.code in {400, 402, 403, 404, 422}
                and ("model" in detail.lower() or error.code == 404)
            ):
                log(f"NOTE  {label}: {PREFERRED_MODEL} unavailable, using {FALLBACK_MODEL}")
                model = FALLBACK_MODEL
                continue
            retryable = error.code in {408, 409, 429, 500, 502, 503, 504}
            reason = f"HTTP {error.code}: {detail}"
        except (urllib.error.URLError, TimeoutError) as error:
            retryable = True
            reason = f"{type(error).__name__}: {error}"
        if not retryable or attempt == max_attempts:
            raise GenerationError(f"{label} failed after {attempt} attempt(s): {reason}")
        delay = min(60.0, 2 ** (attempt - 1) * 3.0 + random.random() * 2.0)
        log(f"RETRY {label}: {reason}; waiting {delay:.1f}s")
        time.sleep(delay)
    raise AssertionError("retry loop exited unexpectedly")


def sample_paths(track: dict[str, Any]) -> tuple[Path, Path, Path]:
    """Return master, evidence, and loop paths for one sampled track."""
    tier_directory = SAMPLE_DIRECTORY / track["intensityTier"]
    master = tier_directory / f"{track['filename']}_EL.mp3"
    evidence = tier_directory / f"{track['id']}_EL.json"
    loop = LOOP_DIRECTORY / f"{track['filename']}_EL.caf"
    return master, evidence, loop


def outputs_are_valid(track: dict[str, Any]) -> bool:
    """Return whether one sample's master, evidence, and loop already validate."""
    master, evidence, loop = sample_paths(track)
    try:
        if not master.is_file() or master.stat().st_size == 0:
            return False
        if probe_audio(master)["duration"] < 28.0:
            return False
        validate_app_audio(loop)
        return bool(json.loads(evidence.read_text(encoding="utf-8")).get("model"))
    except (GenerationError, OSError, ValueError, TypeError, json.JSONDecodeError):
        return False


def generate_sample(
    track: dict[str, Any],
    api_key: str,
    max_attempts: int,
    force: bool,
) -> dict[str, Any]:
    """Generate one ElevenLabs sample plus its mastered loop, resumably."""
    master, evidence, loop = sample_paths(track)
    label = f"EL {track['intensityName']} {track['number']:03d} {track['displayName']}"
    if not force and outputs_are_valid(track):
        log(f"SKIP  {label}")
        return {"id": track["id"], "status": "skipped"}
    master.parent.mkdir(parents=True, exist_ok=True)
    LOOP_DIRECTORY.mkdir(parents=True, exist_ok=True)
    log(f"START {label}")
    with tempfile.TemporaryDirectory(prefix="rise-elevenlabs-") as temporary:
        work_directory = Path(temporary)
        pending_master = work_directory / "master.mp3"
        pending_loop = work_directory / loop.name
        prompt = make_prompt(track)
        for attempt in range(1, max_attempts + 1):
            audio, record = request_music(prompt, api_key, max_attempts, label)
            pending_master.write_bytes(audio)
            metadata = probe_audio(pending_master)
            if metadata["duration"] >= 28.0:
                break
            if attempt == max_attempts:
                raise GenerationError(f"{label}: source stayed shorter than 28s")
            log(f"RETRY {label}: source was {metadata['duration']:.1f}s")
        record["trackID"] = track["id"]
        record["prompt"] = prompt
        record["sourceAudio"] = {
            "duration": metadata["duration"],
            "size": metadata["size"],
            "codec_name": metadata["codec_name"],
            "sample_rate": metadata["sample_rate"],
            "channels": metadata["channels"],
            "sha256": hashlib.sha256(pending_master.read_bytes()).hexdigest(),
        }
        master_loop(pending_master, pending_loop, work_directory)
        loop_metadata = validate_app_audio(pending_loop)
        pending_master.replace(master)
        evidence.write_text(json.dumps(record, indent=2) + "\n", encoding="utf-8")
        pending_loop.replace(loop)
    log(
        f"DONE  {label}: master {record['sourceAudio']['size'] / 1024:.0f} KiB; "
        f"loop {loop_metadata['size'] / 1024:.0f} KiB"
    )
    return {"id": track["id"], "status": "generated"}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--force", action="store_true")
    parser.add_argument("--limit", type=int)
    parser.add_argument("--workers", type=int, default=3)
    parser.add_argument("--max-attempts", type=int, default=4)
    parser.add_argument("--env-file", type=Path, default=DEFAULT_ENV_FILE)
    arguments = parser.parse_args()

    catalog = load_catalog_v4()
    selected = select_samples(catalog)
    if arguments.limit is not None:
        selected = selected[: max(0, arguments.limit)]
    api_key = ""
    for name in ("ELEVEN_LABS_KEY", "ELEVENLABS_API_KEY", "ELEVEN_API_KEY"):
        api_key = load_environment_key(name, arguments.env_file)
        if api_key:
            break
    if not api_key and any(
        arguments.force or not outputs_are_valid(track) for track in selected
    ):
        raise GenerationError("No ElevenLabs API key found for missing samples")

    failures: list[str] = []
    with concurrent.futures.ThreadPoolExecutor(max_workers=arguments.workers) as executor:
        future_map = {
            executor.submit(
                generate_sample, track, api_key, arguments.max_attempts, arguments.force
            ): track
            for track in selected
        }
        for future in concurrent.futures.as_completed(future_map):
            track = future_map[future]
            try:
                future.result()
            except Exception as error:
                failures.append(f"{track['id']}: {error}")
                log(f"FAIL  {track['id']}: {error}")
    manifest = [
        {
            "id": track["id"],
            "intensityTier": track["intensityTier"],
            "displayName": track["displayName"],
            "artistName": track["artistName"],
            "genreName": track["genreName"],
            "vocalistGender": track["vocalistGender"],
            "language": track["language"],
            "master": str(sample_paths(track)[0].relative_to(PROJECT_ROOT)),
            "loop": str(sample_paths(track)[2].relative_to(PROJECT_ROOT)),
            "valid": outputs_are_valid(track),
        }
        for track in select_samples(catalog)
    ]
    SAMPLE_MANIFEST_PATH.parent.mkdir(parents=True, exist_ok=True)
    SAMPLE_MANIFEST_PATH.write_text(
        json.dumps(manifest, indent=2, ensure_ascii=False) + "\n", encoding="utf-8"
    )
    if failures:
        log(f"ElevenLabs sampling completed with {len(failures)} failure(s).")
        return 1
    log(f"SUCCESS: {len(selected)} ElevenLabs samples validated in {SAMPLE_DIRECTORY}")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except GenerationError as error:
        log(f"ERROR: {error}")
        raise SystemExit(1) from error
