#!/usr/bin/env python3
"""Generate Shad's incoming-call ringtone: an ElevenLabs sound effect stitched
into an exact, seamless 10-second loop.

Mirrors the bridge-crossfade technique in master_loop_v6.py (body starts past
the loop point; the tail after the loop point is crossfaded into the head) but
without the bar-math tempo work that only applies to the alarm music catalog --
a ringtone just needs a click-free wraparound.

Usage:
  generate_ringtone.py OUT.m4a --seconds 10 --crossfade 0.35
"""

from __future__ import annotations

import argparse
import os
import subprocess
import sys
import tempfile
from pathlib import Path

import requests
from dotenv import load_dotenv

DEFAULT_ENV_FILE = Path("/Users/kevin/code/kevin/academic-slop/omni/.env")
PROMPT = (
    "Cheerful electronic smartphone ringtone, bright marimba-style bell "
    "pattern repeating in a clear two-beat phrase with a distinct pause "
    "between phrases, no voice, no music bed, clean and simple"
)


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


def generate_sound_effect(
    api_key: str, prompt: str, duration_seconds: float, out_path: Path
) -> None:
    """Call the ElevenLabs sound-generation endpoint and save the raw audio."""
    url = "https://api.elevenlabs.io/v1/sound-generation"
    payload = {
        "text": prompt,
        "duration_seconds": duration_seconds,
        "prompt_influence": 0.4,
    }
    headers = {
        "xi-api-key": api_key,
        "Content-Type": "application/json",
        "Accept": "audio/mpeg",
    }
    response = requests.post(url, headers=headers, json=payload, timeout=120)
    response.raise_for_status()
    out_path.write_bytes(response.content)


def run(cmd: list[str]) -> None:
    subprocess.run(cmd, check=True, capture_output=True)


def stitch_seamless_loop(
    raw_path: Path, out_wav: Path, loop_seconds: float, crossfade_seconds: float
) -> None:
    """Crossfade raw_path's tail into its head so it loops without a click.

    body   = raw[crossfade : loop_seconds]                     (steady middle)
    bridge = acrossfade(raw[loop_seconds : loop_seconds+cf], raw[0:cf])
    final  = bridge + body, exactly loop_seconds long.
    """
    with tempfile.TemporaryDirectory() as td_str:
        td = Path(td_str)
        head, tail, body, bridged = (
            td / "head.wav",
            td / "tail.wav",
            td / "body.wav",
            td / "bridged.wav",
        )
        run([
            "ffmpeg", "-y", "-v", "error", "-i", str(raw_path),
            "-ss", "0", "-to", str(crossfade_seconds), str(head),
        ])
        run([
            "ffmpeg", "-y", "-v", "error", "-i", str(raw_path),
            "-ss", str(loop_seconds), "-to", str(loop_seconds + crossfade_seconds), str(tail),
        ])
        run([
            "ffmpeg", "-y", "-v", "error", "-i", str(raw_path),
            "-ss", str(crossfade_seconds), "-to", str(loop_seconds), str(body),
        ])
        run([
            "ffmpeg", "-y", "-v", "error",
            "-i", str(tail), "-i", str(head),
            "-filter_complex",
            f"[0:a][1:a]acrossfade=d={crossfade_seconds}:c1=tri:c2=tri[a]",
            "-map", "[a]", str(bridged),
        ])
        concat_list = td / "concat.txt"
        concat_list.write_text(f"file '{bridged}'\nfile '{body}'\n")
        run([
            "ffmpeg", "-y", "-v", "error", "-f", "concat", "-safe", "0",
            "-i", str(concat_list), "-c", "copy", str(out_wav),
        ])


def encode_audio(wav_path: Path, out_path: Path) -> None:
    """Encode the seamless loop as small mono AAC, container inferred from out_path's extension."""
    run([
        "ffmpeg", "-y", "-v", "error", "-i", str(wav_path),
        "-ac", "1", "-ar", "44100", "-c:a", "aac", "-b:a", "96k",
        str(out_path),
    ])


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("output", type=Path, help="Output .caf path")
    parser.add_argument("--seconds", type=float, default=10.0)
    parser.add_argument("--crossfade", type=float, default=0.35)
    parser.add_argument("--env-file", type=Path, default=DEFAULT_ENV_FILE)
    parser.add_argument("--prompt", default=PROMPT)
    parser.add_argument("--keep-raw", type=Path, default=None, help="Also save the raw generation for inspection")
    args = parser.parse_args()

    api_key = load_api_key(args.env_file)

    with tempfile.TemporaryDirectory() as td_str:
        td = Path(td_str)
        raw_mp3 = td / "raw.mp3"
        raw_seconds = args.seconds + args.crossfade
        print(f"Generating {raw_seconds:.2f}s sound effect from ElevenLabs...")
        generate_sound_effect(api_key, args.prompt, raw_seconds, raw_mp3)
        if args.keep_raw:
            args.keep_raw.write_bytes(raw_mp3.read_bytes())

        loop_wav = td / "loop.wav"
        print(f"Stitching a seamless {args.seconds:.2f}s loop (crossfade {args.crossfade:.2f}s)...")
        stitch_seamless_loop(raw_mp3, loop_wav, args.seconds, args.crossfade)

        args.output.parent.mkdir(parents=True, exist_ok=True)
        encode_audio(loop_wav, args.output)

    size_kb = args.output.stat().st_size / 1024
    print(f"Wrote {args.output} ({size_kb:.1f} KB)")


if __name__ == "__main__":
    main()
