#!/usr/bin/env python3
"""Generate the false-squat taunt clips with ElevenLabs.

Shad heckles you when the gauge fills but the recognizer refuses to credit the
rep — the "waving your arm in bed" case. Clips land as bundle-ready m4a beside
the motivational lines.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import time
from concurrent.futures import ThreadPoolExecutor, as_completed
from pathlib import Path
from typing import Any

import requests
from dotenv import load_dotenv


VOICE_ID = "1FpbYn3wr6bZTt5J6C0m"
MODEL_ID = "eleven_v3"
OUTPUT_FORMAT = "mp3_44100_128"
DIRECTION = "[condescending, smug, disappointed, mocking]"
DEFAULT_ENV_FILE = Path("/Users/kevin/code/kevin/academic-slop/omni/.env")
DEFAULT_OUTPUT_DIR = Path("RiseAndGrind/Resources/FalseSquatTaunts")

# Twenty ways of telling you that was not a squat.
PHRASES = [
    "Sorry, I don't think that counts.",
    "Are you even trying?",
    "I can tell if you're just lying in bed moving your arms.",
    "Worst... squat... ever.",
    "That was an arm. I asked for a body.",
    "Nice wrist workout. Now squat.",
    "The phone moved. You didn't.",
    "I've seen deeper puddles.",
    "That's not a squat, that's a stretch.",
    "You're cheating a machine. Think about that.",
    "Gravity is not impressed.",
    "Zero reps. Infinite excuses.",
    "Your arm is in phenomenal shape. Your legs aren't.",
    "I watched that whole thing. Nothing happened.",
    "Do you think I can't see you?",
    "Half a rep is a whole nothing.",
    "That's the effort of a man who stays average.",
    "Congratulations, you fooled absolutely no one.",
    "Blanket still on? Yeah, thought so.",
    "Try it again, but with your legs this time.",
]


def slugify(text: str) -> str:
    """Convert a phrase into a stable lowercase filename component."""
    slug = re.sub(r"[^a-z0-9]+", "_", text.lower()).strip("_")
    return slug[:44].strip("_") or "taunt"


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


def encode_m4a(source: Path, destination: Path) -> None:
    """Match the bundled motivational lines: mono 24 kHz AAC."""
    subprocess.run(
        [
            "ffmpeg", "-y", "-v", "error",
            "-i", str(source),
            "-ac", "1", "-ar", "24000",
            "-c:a", "aac", "-b:a", "48k",
            "-movflags", "+faststart",
            str(destination),
        ],
        check=True,
    )


def generate_clip(
    index: int,
    phrase: str,
    output_dir: Path,
    api_key: str,
    force: bool,
) -> dict[str, Any]:
    """Generate one taunt clip and return its manifest record."""
    stem = f"FalseSquat-{index:03d}_{slugify(phrase)}"
    final_path = output_dir / f"{stem}.m4a"
    text_prompt = f"{DIRECTION} {phrase}"

    if final_path.exists() and final_path.stat().st_size > 1_000 and not force:
        return {
            "index": index,
            "phrase": phrase,
            "filename": final_path.name,
            "bytes": final_path.stat().st_size,
            "status": "existing",
        }

    url = (
        f"https://api.elevenlabs.io/v1/text-to-speech/{VOICE_ID}"
        f"?output_format={OUTPUT_FORMAT}"
    )
    payload = {
        "text": text_prompt,
        "model_id": MODEL_ID,
        "voice_settings": {"stability": 0.3},
        "seed": 20_000 + index,
    }
    headers = {
        "xi-api-key": api_key,
        "Content-Type": "application/json",
        "Accept": "audio/mpeg",
    }

    last_error = ""
    for attempt in range(1, 5):
        response = requests.post(url, headers=headers, json=payload, timeout=180)
        if response.ok:
            scratch = output_dir / f".{stem}.mp3"
            scratch.write_bytes(response.content)
            encode_m4a(scratch, final_path)
            scratch.unlink(missing_ok=True)
            return {
                "index": index,
                "phrase": phrase,
                "filename": final_path.name,
                "bytes": final_path.stat().st_size,
                "status": "generated",
            }
        last_error = f"HTTP {response.status_code}: {response.text[:200]}"
        time.sleep(2 * attempt)

    raise RuntimeError(f"Failed to generate {stem}: {last_error}")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output-dir", type=Path, default=DEFAULT_OUTPUT_DIR)
    parser.add_argument("--env-file", type=Path, default=DEFAULT_ENV_FILE)
    parser.add_argument("--force", action="store_true")
    parser.add_argument("--workers", type=int, default=4)
    args = parser.parse_args()

    api_key = load_api_key(args.env_file)
    args.output_dir.mkdir(parents=True, exist_ok=True)

    records: list[dict[str, Any]] = []
    with ThreadPoolExecutor(max_workers=args.workers) as pool:
        futures = {
            pool.submit(generate_clip, index, phrase, args.output_dir, api_key, args.force): index
            for index, phrase in enumerate(PHRASES, start=1)
        }
        for future in as_completed(futures):
            records.append(future.result())

    records.sort(key=lambda record: record["index"])
    # A bare manifest.json would collide with the sound library's in the bundle.
    manifest = args.output_dir / "FalseSquatTaunts.manifest.json"
    manifest.write_text(json.dumps({"voiceId": VOICE_ID, "clips": records}, indent=2) + "\n")

    generated = sum(1 for record in records if record["status"] == "generated")
    print(f"{len(records)} taunts ({generated} newly generated) in {args.output_dir}")


if __name__ == "__main__":
    main()
