#!/usr/bin/env python3
"""Generate the RiseAndGrind motivational voice clip collection with ElevenLabs."""

from __future__ import annotations

import argparse
import json
import os
import re
import time
from concurrent.futures import ThreadPoolExecutor, as_completed
from pathlib import Path
from typing import Any

import requests
from dotenv import load_dotenv


VOICE_ID = "DGzg6RaUqxGRTHSBjfgF"
MODEL_ID = "eleven_v3"
OUTPUT_FORMAT = "mp3_44100_128"
DIRECTION = "[domineering, alpha, angry, terse, impatient]"
DEFAULT_ENV_FILE = Path("/Users/kevin/code/kevin/academic-slop/omni/.env")
DEFAULT_OUTPUT_DIR = Path("GeneratedSamples/ElevenLabsDGzgV3Direct")
PHRASES = [
    "No days off.",
    "Sleep is weak.",
    "Outwork everyone today.",
    "Discipline beats motivation.",
    "Comfort is the enemy.",
    "Bet on yourself.",
    "Build the empire.",
    "Stack wins daily.",
    "Go get it.",
    "Level up now.",
    "Execute, don't wait.",
    "Grind now, shine later.",
    "Own your morning.",
    "Save yourself first.",
    "Excuses don't pay.",
    "Sweat now, flex later.",
    "Grind never stops.",
    "Find a way.",
    "Beat your competition.",
    "Hustle in silence.",
    "Build or fall behind.",
    "Comfort kills dreams.",
    "Nobody cares, work.",
    "Relentless, always relentless.",
    "Discomfort equals growth.",
    "Pain fuels progress.",
    "Stay hungry, humble.",
    "Play the long game.",
    "Consistency compounds daily.",
    "Beat yesterday's you.",
    "Wait for nothing.",
    "Adversity builds greatness.",
    "Sacrifice now, win later.",
    "Reject average today.",
    "Do it scared.",
    "Chase vision, not validation.",
    "No 8-hour excuses.",
    "Grind is equalizer.",
    "Show up anyway.",
    "Dreams need work.",
    "Get uncomfortable now.",
    "Take the stairs.",
    "Results talk loudest.",
    "Every rep counts.",
    "You're the limit.",
    "Earned in darkness.",
    "Create your luck.",
    "Stop scrolling, build.",
    "Secure the future.",
    "Grind is reward.",
    "Discipline builds bridges.",
    "Rest when rich.",
    "Hard work wins.",
    "Silence your haters.",
    "No shortcuts exist.",
    "Just don't quit.",
    "Obsess, don't wish.",
    "1% better daily.",
    "Do it now.",
    "Grit over comfort.",
    "Small wins compound.",
    "Grind today, always.",
    "Speed over hesitation.",
    "Market rewards obsession.",
    "Work hardest, always.",
    "Habits build destiny.",
    "Build momentum daily.",
    "Focus beats motivation.",
    "Win the morning.",
    "Struggle is tuition.",
    "Grind ignores feelings.",
    "Show up anyway.",
    "Excuses expire today.",
    "Get after it.",
    "Discipline equals freedom.",
    "Don't ever quit.",
    "Build the unimaginable.",
    "Setbacks fuel comebacks.",
    "Stay in arena.",
    "Do more, always.",
    "Own your life.",
    "No finish line.",
    "Beat complacency daily.",
    "Fortune favors relentless.",
    "Sweat equity wins.",
    "Trust the process.",
    "Never born average.",
    "Outwork, outlearn, outlast.",
    "More reps, always.",
    "Lock in now.",
    "Execute and repeat.",
    "Win in silence.",
    "Push past limits.",
    "Grind builds character.",
    "Chase greatness daily.",
    "No excuses allowed.",
    "Earn it daily.",
    "Stay locked in.",
    "Keep grinding forward.",
    "Rise and grind.",
]


def slugify(text: str) -> str:
    """Convert a phrase into a stable lowercase filename component."""
    slug = re.sub(r"[^a-z0-9]+", "_", text.lower()).strip("_")
    return slug or "clip"


def with_exclamation(text: str) -> str:
    """Replace terminal sentence punctuation with one exclamation mark."""
    return f"{text.rstrip('!?.')}!"


def load_api_key(env_file: Path) -> str:
    """Load an ElevenLabs API key without copying it into the project."""
    if env_file.exists():
        load_dotenv(env_file)
    key = (
        os.environ.get("ELEVEN_LABS_KEY")
        or os.environ.get("ELEVENLABS_API_KEY")
        or os.environ.get("ELEVEN_API_KEY")
    )
    if not key:
        raise RuntimeError(f"No ElevenLabs API key found in the environment or {env_file}")
    return key


def generate_clip(
    index: int,
    phrase: str,
    output_dir: Path,
    api_key: str,
    force: bool,
) -> dict[str, Any]:
    """Generate one motivational clip and return its manifest record."""
    filename = f"{index:03d}_{slugify(phrase)}.mp3"
    output_path = output_dir / filename
    text_prompt = f"{DIRECTION} {with_exclamation(phrase)}"
    if output_path.exists() and output_path.stat().st_size > 1_000 and not force:
        return {
            "index": index,
            "phrase": phrase,
            "textPrompt": text_prompt,
            "filename": filename,
            "bytes": output_path.stat().st_size,
            "status": "existing",
        }

    url = (
        f"https://api.elevenlabs.io/v1/text-to-speech/{VOICE_ID}"
        f"?output_format={OUTPUT_FORMAT}"
    )
    payload = {
        "text": text_prompt,
        "model_id": MODEL_ID,
        "voice_settings": {"stability": 0.2},
        "seed": 10_000 + index,
    }
    headers = {
        "xi-api-key": api_key,
        "Content-Type": "application/json",
        "Accept": "audio/mpeg",
    }

    last_error = ""
    for attempt in range(1, 5):
        response = requests.post(
            url,
            headers=headers,
            json=payload,
            timeout=180,
        )
        if response.ok:
            output_path.write_bytes(response.content)
            return {
                "index": index,
                "phrase": phrase,
                "textPrompt": text_prompt,
                "filename": filename,
                "bytes": output_path.stat().st_size,
                "status": "generated",
            }

        try:
            detail = response.json().get("detail", response.text[:500])
        except ValueError:
            detail = response.text[:500]
        last_error = f"HTTP {response.status_code}: {detail}"
        if response.status_code not in {408, 409, 429, 500, 502, 503, 504}:
            break
        time.sleep(min(2**attempt, 12))

    raise RuntimeError(f"Clip {index:03d} failed after retries: {last_error}")


def write_manifest(output_dir: Path, records: list[dict[str, Any]]) -> Path:
    """Write a JSON manifest describing the generated collection."""
    manifest_path = output_dir / "manifest.json"
    payload = {
        "voiceId": VOICE_ID,
        "modelId": MODEL_ID,
        "outputFormat": OUTPUT_FORMAT,
        "direction": DIRECTION,
        "clipCount": len(records),
        "clips": sorted(records, key=lambda record: record["index"]),
    }
    manifest_path.write_text(
        json.dumps(payload, indent=2, ensure_ascii=False) + "\n",
        encoding="utf-8",
    )
    return manifest_path


def parse_args() -> argparse.Namespace:
    """Parse command-line options."""
    parser = argparse.ArgumentParser()
    parser.add_argument("--env-file", type=Path, default=DEFAULT_ENV_FILE)
    parser.add_argument("--output-dir", type=Path, default=DEFAULT_OUTPUT_DIR)
    parser.add_argument("--workers", type=int, default=3)
    parser.add_argument("--start-index", type=int, default=1)
    parser.add_argument("--end-index", type=int, default=100)
    parser.add_argument("--force", action="store_true")
    return parser.parse_args()


def main() -> None:
    """Generate all clips and write their manifest."""
    args = parse_args()
    if len(PHRASES) != 100:
        raise RuntimeError(f"Expected 100 phrases, found {len(PHRASES)}")
    if not 1 <= args.start_index <= args.end_index <= len(PHRASES):
        raise RuntimeError(
            "Expected 1 <= start-index <= end-index <= number of phrases"
        )

    args.output_dir.mkdir(parents=True, exist_ok=True)
    api_key = load_api_key(args.env_file)
    records: list[dict[str, Any]] = []
    failures: list[str] = []
    selected_phrases = [
        (index, phrase)
        for index, phrase in enumerate(PHRASES, start=1)
        if args.start_index <= index <= args.end_index
    ]

    with ThreadPoolExecutor(max_workers=max(1, args.workers)) as executor:
        futures = {
            executor.submit(
                generate_clip,
                index,
                phrase,
                args.output_dir,
                api_key,
                args.force,
            ): index
            for index, phrase in selected_phrases
        }
        for future in as_completed(futures):
            index = futures[future]
            try:
                record = future.result()
                records.append(record)
                print(
                    f"[{len(records):03d}/{len(selected_phrases):03d}] "
                    f"{record['status']}: "
                    f"{record['filename']}",
                    flush=True,
                )
            except Exception as error:
                failures.append(f"{index:03d}: {error}")
                print(f"[failed] {index:03d}: {error}", flush=True)

    records_by_index = {record["index"]: record for record in records}
    for index, phrase in enumerate(PHRASES, start=1):
        if index in records_by_index:
            continue
        filename = f"{index:03d}_{slugify(phrase)}.mp3"
        output_path = args.output_dir / filename
        if output_path.exists() and output_path.stat().st_size > 1_000:
            records_by_index[index] = {
                "index": index,
                "phrase": phrase,
                "textPrompt": f"{DIRECTION} {with_exclamation(phrase)}",
                "filename": filename,
                "bytes": output_path.stat().st_size,
                "status": "existing",
            }

    manifest_path = write_manifest(
        args.output_dir,
        list(records_by_index.values()),
    )
    print(f"Manifest: {manifest_path}")
    if failures:
        raise RuntimeError("\n".join(failures))


if __name__ == "__main__":
    main()
