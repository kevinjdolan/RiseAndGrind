#!/usr/bin/env python3
"""Generate the v5 audition sample: 10 songs per tier on BOTH Lyria and ElevenLabs.

Everything lands in scratch_data/V5Samples — masters, evidence, and mastered
29-second loop CAFs per provider — so the installed v4 library is untouched.
Selection is deterministic: per tier, genre-diverse 5F/5M; the abrasive picks
must include at least three songs with vulgarity score >= 3 so the new
profanity gradient is auditioned.
"""

from __future__ import annotations

import argparse
import concurrent.futures
import hashlib
import json
import tempfile
from pathlib import Path
from typing import Any

import generate_elevenlabs_music_samples as elevenlabs
import generate_music_library_v4 as lyria
from generate_music_library_v4 import GenerationError, log, master_loop, probe_audio, validate_app_audio
from music_catalog_v4 import (
    PROJECT_ROOT,
    TIER_PROFILES_V4,
    V5_VULGARITY_LIMITS,
    validate_catalog_v4,
    vulgarity_score,
)

CATALOG_V5_PATH = PROJECT_ROOT / "scratch_data" / "music_catalog_v5.json"
SAMPLE_ROOT = PROJECT_ROOT / "scratch_data" / "V5Samples"
LOOP_DIRECTORY = SAMPLE_ROOT / "loops"
MANIFEST_PATH = SAMPLE_ROOT / "samples_manifest.json"
SAMPLES_PER_TIER = 10
PROVIDERS = ("lyria", "elevenlabs")


def load_catalog_v5() -> tuple[dict[str, Any], ...]:
    """Load and validate the v5 catalog with the v5 vulgarity policy."""
    catalog = json.loads(CATALOG_V5_PATH.read_text(encoding="utf-8"))
    problems = validate_catalog_v4(catalog, vulgarity_limits=V5_VULGARITY_LIMITS)
    if problems:
        detail = "\n".join(f"- {p}" for p in problems[:20])
        raise GenerationError(f"v5 catalog failed validation:\n{detail}")
    return tuple(catalog)


def select_samples(catalog: tuple[dict[str, Any], ...]) -> list[dict[str, Any]]:
    """Deterministically pick 10 genre-diverse songs per tier, 5F/5M."""
    selected: list[dict[str, Any]] = []
    for tier in TIER_PROFILES_V4:
        tier_tracks = [t for t in catalog if t["intensityTier"] == tier.identifier]
        picks: list[dict[str, Any]] = []
        seen_genres: set[str] = set()

        def take(track: dict[str, Any]) -> None:
            picks.append(track)
            seen_genres.add(track["genreName"].lower())

        if tier.identifier == "abrasive":
            spicy = sorted(
                (t for t in tier_tracks if vulgarity_score(t) >= 3),
                key=lambda t: (-vulgarity_score(t), t["number"]),
            )
            for track in spicy:
                if len(picks) == 3:
                    break
                if track["genreName"].lower() not in seen_genres:
                    take(track)
        wanted = "female"
        females = sum(1 for t in picks if t["vocalistGender"] == "female")
        males = len(picks) - females
        for relax_genre in (False, True):
            for track in tier_tracks:
                if len(picks) == SAMPLES_PER_TIER:
                    break
                females = sum(1 for t in picks if t["vocalistGender"] == "female")
                males = len(picks) - females
                if females >= 5:
                    wanted = "male"
                elif males >= 5:
                    wanted = "female"
                if track in picks or track["vocalistGender"] != wanted:
                    continue
                if not relax_genre and track["genreName"].lower() in seen_genres:
                    continue
                take(track)
                wanted = "male" if wanted == "female" else "female"
            if len(picks) == SAMPLES_PER_TIER:
                break
        if len(picks) != SAMPLES_PER_TIER:
            raise GenerationError(
                f"Selected {len(picks)} samples for {tier.identifier}, expected 10"
            )
        selected.extend(sorted(picks, key=lambda t: t["number"]))
    return selected


def sample_paths(track: dict[str, Any], provider: str) -> tuple[Path, Path, Path]:
    """Return master, evidence, and loop paths for one provider sample."""
    tier_directory = SAMPLE_ROOT / provider / track["intensityTier"]
    master = tier_directory / f"{track['filename']}.mp3"
    evidence = tier_directory / f"{track['id']}.json"
    loop = LOOP_DIRECTORY / f"{track['filename']}_{provider}.caf"
    return master, evidence, loop


def outputs_are_valid(track: dict[str, Any], provider: str) -> bool:
    """Return whether one sample already validates."""
    master, evidence, loop = sample_paths(track, provider)
    try:
        if not master.is_file() or probe_audio(master)["duration"] < 28.0:
            return False
        validate_app_audio(loop)
        record = json.loads(evidence.read_text(encoding="utf-8"))
        return bool(record.get("model")) and record.get("catalogVersion") == 5
    except (GenerationError, OSError, ValueError, TypeError, json.JSONDecodeError):
        return False


def generate_sample(
    track: dict[str, Any],
    provider: str,
    keys: dict[str, str],
    max_attempts: int,
    force: bool,
) -> None:
    """Generate one provider sample plus its mastered loop, resumably."""
    master, evidence, loop = sample_paths(track, provider)
    label = f"{provider} {track['intensityName']} {track['number']:03d} {track['displayName']}"
    if not force and outputs_are_valid(track, provider):
        log(f"SKIP  {label}")
        return
    master.parent.mkdir(parents=True, exist_ok=True)
    LOOP_DIRECTORY.mkdir(parents=True, exist_ok=True)
    log(f"START {label}")
    with tempfile.TemporaryDirectory(prefix="rise-v5-sample-") as temporary:
        work_directory = Path(temporary)
        pending_master = work_directory / "master.mp3"
        pending_loop = work_directory / loop.name
        if provider == "lyria":
            prompt = lyria.make_prompt(track)
            audio, record = lyria.request_audio(prompt, keys["lyria"], max_attempts, label)
        else:
            prompt = elevenlabs.make_prompt(track)
            audio, record = elevenlabs.request_music(
                prompt, keys["elevenlabs"], max_attempts, label
            )
        pending_master.write_bytes(audio)
        metadata = probe_audio(pending_master)
        if metadata["duration"] < 28.0:
            raise GenerationError(f"{label}: source only {metadata['duration']:.1f}s")
        record.update(
            {
                "trackID": track["id"],
                "catalogVersion": 5,
                "prompt": prompt,
                "vulgarityScore": vulgarity_score(track),
                "sourceAudio": {
                    "duration": metadata["duration"],
                    "size": metadata["size"],
                    "sha256": hashlib.sha256(audio).hexdigest(),
                },
            }
        )
        master_loop(pending_master, pending_loop, work_directory)
        validate_app_audio(pending_loop)
        pending_master.replace(master)
        evidence.write_text(json.dumps(record, indent=2) + "\n", encoding="utf-8")
        pending_loop.replace(loop)
    log(f"DONE  {label}")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--force", action="store_true")
    parser.add_argument("--provider", choices=PROVIDERS)
    parser.add_argument("--workers", type=int, default=4)
    parser.add_argument("--max-attempts", type=int, default=4)
    arguments = parser.parse_args()

    catalog = load_catalog_v5()
    selected = select_samples(catalog)
    providers = [arguments.provider] if arguments.provider else list(PROVIDERS)
    keys = {
        "lyria": lyria.load_environment_key("GEMINI_API_KEY"),
        "elevenlabs": next(
            (
                key
                for name in ("ELEVEN_LABS_KEY", "ELEVENLABS_API_KEY", "ELEVEN_API_KEY")
                if (key := lyria.load_environment_key(name))
            ),
            "",
        ),
    }
    for provider in providers:
        if not keys[provider] and any(
            arguments.force or not outputs_are_valid(t, provider) for t in selected
        ):
            raise GenerationError(f"Missing API key for {provider}")

    jobs = [(track, provider) for provider in providers for track in selected]
    failures: list[str] = []
    with concurrent.futures.ThreadPoolExecutor(max_workers=arguments.workers) as executor:
        futures = {
            executor.submit(
                generate_sample, track, provider, keys, arguments.max_attempts, arguments.force
            ): (track, provider)
            for track, provider in jobs
        }
        for future in concurrent.futures.as_completed(futures):
            track, provider = futures[future]
            try:
                future.result()
            except Exception as error:
                failures.append(f"{provider}/{track['id']}: {error}")
                log(f"FAIL  {provider}/{track['id']}: {error}")

    manifest = [
        {
            "id": track["id"],
            "intensityTier": track["intensityTier"],
            "displayName": track["displayName"],
            "artistName": track["artistName"],
            "genreName": track["genreName"],
            "vocalistGender": track["vocalistGender"],
            "language": track["language"],
            "vulgarityScore": vulgarity_score(track),
            "loops": {
                provider: str(sample_paths(track, provider)[2].relative_to(PROJECT_ROOT))
                for provider in PROVIDERS
            },
            "valid": {
                provider: outputs_are_valid(track, provider) for provider in PROVIDERS
            },
        }
        for track in selected
    ]
    MANIFEST_PATH.parent.mkdir(parents=True, exist_ok=True)
    MANIFEST_PATH.write_text(
        json.dumps(manifest, indent=2, ensure_ascii=False) + "\n", encoding="utf-8"
    )
    if failures:
        log(f"v5 sampling completed with {len(failures)} failure(s).")
        return 1
    log(f"SUCCESS: {len(jobs)} v5 samples validated under {SAMPLE_ROOT}")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except GenerationError as error:
        log(f"ERROR: {error}")
        raise SystemExit(1) from error
