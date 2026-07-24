#!/usr/bin/env python3
"""Generate the 30-second Rise & Grind thrash-vocal sample with Lyria 3 Clip."""

from __future__ import annotations

import argparse
import base64
import json
import os
from pathlib import Path
import subprocess
import tempfile
from typing import Any
import urllib.error
import urllib.request


MODEL = "lyria-3-clip-preview"
ENDPOINT = "https://generativelanguage.googleapis.com/v1beta/interactions"
PROJECT_ROOT = Path(__file__).resolve().parent.parent
DEFAULT_OUTPUT = PROJECT_ROOT / "GeneratedSamples" / "WakeUpThrashVocalSample.mp3"


def build_prompt() -> str:
    """Return a tightly directed prompt with the requested opening lyric."""
    return " ".join(
        (
            "Create an original exactly 30-second heavy thrash-metal wake-up track.",
            "Start at full intensity on the first beat at 220 BPM with a vicious, tightly "
            "palm-muted downpicked electric-guitar riff, aggressive bass guitar, and nonstop "
            "double-bass kick drums with explosive snare accents.",
            "Use a female lead vocalist performing only harsh, raspy screamed vocals; no clean "
            "singing, no male voice, and no spoken intro.",
            "The very first sung words must be these exact lyrics, preserving their wording and order:",
            '"Wake up, wake up, wake up, you\'re such a piece of shit; if I had the time I\'d kill you '
            'but I gotta pick up my kids!"',
            "Make every word intelligible above the guitars and drums.",
            "After that opening line, use repeated harsh shouts of 'Wake up!' as a rhythmic refrain, "
            "with short instrumental gaps for the riff and double-kick barrage.",
            "Keep the entire clip abrasive, urgent, rhythmically precise, and relentlessly loud, "
            "then end with a sharp final band hit at exactly 0:30.",
            "Do not imitate any existing song, artist, vocalist, melody, or copyrighted recording.",
        )
    )


def extract_result(payload: dict[str, Any]) -> tuple[bytes, str]:
    """Extract the audio and model-reported lyric sheet from a Lyria response."""
    audio: bytes | None = None
    text_blocks: list[str] = []
    for step in payload.get("steps") or []:
        if step.get("type") != "model_output":
            continue
        for content in step.get("content") or []:
            if content.get("type") == "audio" and content.get("data"):
                audio = base64.b64decode(content["data"])
            elif content.get("type") == "text" and content.get("text"):
                text_blocks.append(str(content["text"]))
    if audio is not None:
        return audio, "\n\n".join(text_blocks)
    if payload.get("error"):
        raise RuntimeError(f"Lyria API error: {payload['error']}")
    raise RuntimeError("Lyria returned no audio block")


def request_clip(api_key: str) -> tuple[bytes, str]:
    """Request one MP3 clip from the Gemini Interactions API."""
    request = urllib.request.Request(
        ENDPOINT,
        data=json.dumps({"model": MODEL, "input": build_prompt()}).encode("utf-8"),
        method="POST",
        headers={
            "Content-Type": "application/json",
            "x-goog-api-key": api_key,
            "User-Agent": "RiseAndGrind-LyriaSample/1.0",
        },
    )
    try:
        with urllib.request.urlopen(request, timeout=900) as response:
            payload = json.loads(response.read())
    except urllib.error.HTTPError as error:
        detail = error.read().decode("utf-8", errors="replace")[:1_000]
        raise RuntimeError(f"Lyria request failed with HTTP {error.code}: {detail}") from error
    return extract_result(payload)


def standardize_clip(source: Path, destination: Path) -> None:
    """Trim the generated MP3 to exactly 30 seconds and keep its peaks below clipping."""
    result = subprocess.run(
        [
            "ffmpeg",
            "-hide_banner",
            "-loglevel",
            "error",
            "-y",
            "-i",
            str(source),
            "-af",
            "atrim=duration=30,asetpts=PTS-STARTPTS,"
            "alimiter=limit=0.891251:attack=5:release=50:level=false",
            "-ar",
            "44100",
            "-ac",
            "2",
            "-c:a",
            "libmp3lame",
            "-b:a",
            "320k",
            str(destination),
        ],
        check=False,
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        raise RuntimeError(f"ffmpeg failed: {result.stderr.strip()[-1_000:]}")


def parse_arguments() -> argparse.Namespace:
    """Parse the optional destination override."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=DEFAULT_OUTPUT)
    return parser.parse_args()


def main() -> int:
    """Generate the sample and atomically place it at the requested destination."""
    arguments = parse_arguments()
    api_key = os.environ.get("GEMINI_API_KEY", "")
    if not api_key:
        raise RuntimeError("GEMINI_API_KEY is required")

    output = arguments.output.expanduser().resolve()
    output.parent.mkdir(parents=True, exist_ok=True)
    audio, lyric_sheet = request_clip(api_key)
    with tempfile.TemporaryDirectory(dir=output.parent) as temporary_directory:
        raw = Path(temporary_directory) / "raw.mp3"
        standardized = Path(temporary_directory) / output.name
        raw.write_bytes(audio)
        standardize_clip(raw, standardized)
        standardized.replace(output)
    if lyric_sheet:
        output.with_suffix(".lyrics.txt").write_text(lyric_sheet + "\n", encoding="utf-8")
    print(output)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
