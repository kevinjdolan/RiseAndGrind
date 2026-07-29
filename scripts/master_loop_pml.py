#!/usr/bin/env python3
"""Master a generated source into a seamless loop CAF using PyMusicLooper.

The v6 chain cut at a whole-bar boundary derived from the planned tempo and
micro-stretched to exactly 29.000 s. The v9 chain instead *discovers* the loop
empirically: PyMusicLooper searches the source for the pair of points whose
audio actually matches, so the wrap lands on real musical repetition rather
than on arithmetic. The loop is then whatever length that discovery says, so
long as it falls in the v9 window of 20 s <= L < 30 s -- no time-stretching,
which means the music keeps its original tempo exactly.

1. Search for loop pairs constrained to the target window, escalating through
   looser analysis settings only when the default pass finds nothing.
2. Pick the longest candidate scoring within SCORE_TOLERANCE of the best, so a
   near-equal but longer loop keeps more of the composed material.
3. Bridge the wrap the same way the v4/v6 graphs do -- crossfade the material
   *after* the loop point into the loop head -- but with a short fade, since a
   discovered loop point already matches and a long fade would only smear it.
4. Apply the phone-speaker chain and encode mono 22.05 kHz IMA4 CAF.
5. Validate duration/codec/rate/size against the v9 window.

Requires the pymusiclooper venv (numpy/librosa/soundfile), NOT system Python:
  .venvs/pml/bin/python scripts/master_loop_pml.py IN.mp3 OUT.caf
"""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import subprocess
import sys
import tempfile
import warnings
from pathlib import Path
from typing import Any

PROJECT_ROOT = Path(__file__).resolve().parent.parent

# v9 loop window: strictly under 30 s, and no shorter than 20 s.
MIN_LOOP_SECONDS = 20.0
MAX_LOOP_SECONDS = 29.99
APP_SAMPLE_RATE = 22_050
MAXIMUM_APP_BYTES = 410_000
# A discovered loop point already matches, so the bridge only needs to be long
# enough to hide a sample-level step, not to blend two different passages.
CROSSFADE_SECONDS = 0.06
SCORE_TOLERANCE = 0.05

# Progressively looser analysis passes; brute force is slow so it comes last.
LADDER: tuple[dict[str, Any], ...] = (
    {},
    {"disable_pruning": True},
    {"disable_pruning": True, "brute_force": True},
)


class MasteringError(RuntimeError):
    """Raised when a source cannot be mastered into a valid v9 loop."""


def run(command: list[str]) -> subprocess.CompletedProcess[str]:
    result = subprocess.run(command, capture_output=True, text=True)
    if result.returncode != 0:
        raise MasteringError(f"{command[0]} failed: {(result.stderr or '')[-400:]}")
    return result


def find_loop(looper, min_seconds: float, max_seconds: float) -> tuple[Any, int]:
    """Return (chosen pair, ladder rung) for the best loop in the window."""
    from pymusiclooper.exceptions import LoopNotFoundError

    for rung, kwargs in enumerate(LADDER):
        try:
            pairs = looper.find_loop_pairs(
                min_loop_duration=min_seconds,
                max_loop_duration=max_seconds,
                **kwargs,
            )
        except LoopNotFoundError:
            continue
        if pairs:
            best = max(p.score for p in pairs)
            viable = [p for p in pairs if p.score >= best - SCORE_TOLERANCE]
            return max(viable, key=lambda p: p.loop_end - p.loop_start), rung
    raise MasteringError(
        f"No loop found between {min_seconds:.1f}s and {max_seconds:.1f}s"
    )


def build_loop(audio, start: int, end: int, rate: int):
    """Slice [start,end) and crossfade the post-loop material into the head.

    Length is preserved exactly: body is (L - fade) long, the bridge is fade
    long, so the result is L. On repeat, the bridge's tail *is* the loop head,
    which is what makes the wrap continuous.
    """
    import numpy as np

    fade = int(CROSSFADE_SECONDS * rate)
    # Only bridge when there is real material after the loop point to fade from.
    fade = min(fade, (end - start) // 4, max(0, len(audio) - end))
    if fade <= 0:
        return audio[start:end]

    body = audio[start + fade : end]
    tail = audio[end : end + fade]
    head = audio[start : start + fade]
    ramp = np.linspace(0.0, 1.0, fade, dtype=np.float32)
    if tail.ndim > 1:
        ramp = ramp[:, None]
    bridge = tail * (1.0 - ramp) + head * ramp
    return np.concatenate([body, bridge])


def _tile(loop, count: int):
    """Repeat the loop `count` times end to end."""
    import numpy as np

    return np.concatenate([loop] * count)


def validate_v9_audio(path: Path) -> dict[str, Any]:
    """Validate codec/rate/channels/size and the 20 s <= duration < 30 s window."""
    if not path.is_file() or path.stat().st_size == 0:
        raise MasteringError(f"Missing app audio: {path}")
    afinfo = run(["afinfo", str(path)]).stdout
    duration_match = re.search(r"estimated duration:\s+([\d.]+) sec", afinfo)
    frames_match = re.search(r"audio\s+(\d+) valid frames", afinfo)
    rate_match = re.search(r"1 ch,\s+(\d+) Hz,\s+ima4", afinfo)
    if not duration_match or not frames_match or not rate_match:
        raise MasteringError(f"Unable to parse compact CAF metadata: {path}")
    duration = float(duration_match.group(1))
    sample_count = int(frames_match.group(1))
    sample_rate = int(rate_match.group(1))
    if sample_rate != APP_SAMPLE_RATE:
        raise MasteringError(f"Unexpected sample rate {sample_rate} in {path}")
    if not (MIN_LOOP_SECONDS <= duration < 30.0):
        raise MasteringError(
            f"Loop is {duration:.3f}s, outside the v9 window "
            f"[{MIN_LOOP_SECONDS}, 30.0): {path}"
        )
    size = path.stat().st_size
    if size > MAXIMUM_APP_BYTES:
        raise MasteringError(f"App audio exceeds {MAXIMUM_APP_BYTES} bytes: {path}")
    return {
        "duration": duration,
        "sampleCount": sample_count,
        "sample_rate": sample_rate,
        "channels": 1,
        "codec_name": "ima4",
        "container": "caf",
        "size": size,
        "sha256": hashlib.sha256(path.read_bytes()).hexdigest(),
    }


def master_loop_pml(
    source: Path,
    destination: Path,
    min_seconds: float = MIN_LOOP_SECONDS,
    max_seconds: float = MAX_LOOP_SECONDS,
) -> dict[str, Any]:
    """Master one generated source into a discovered-loop v9 CAF."""
    warnings.filterwarnings("ignore")
    import soundfile as sf
    from pymusiclooper.core import MusicLooper

    looper = MusicLooper(str(source))
    audio = looper.mlaudio.playback_audio
    rate = looper.mlaudio.rate
    source_seconds = len(audio) / rate
    if source_seconds < min_seconds + 1.0:
        raise MasteringError(
            f"Source is only {source_seconds:.1f}s; need > {min_seconds + 1.0:.1f}s "
            "to find a loop in the v9 window"
        )

    pair, rung = find_loop(looper, min_seconds, max_seconds)
    start, end = int(pair.loop_start), int(pair.loop_end)
    loop = build_loop(audio, start, end, rate)
    loop_seconds = len(loop) / rate

    with tempfile.TemporaryDirectory(prefix="rise-v9-master-") as temporary:
        work = Path(temporary)
        # The EQ/compressor/limiter are stateful, so running them over a single
        # copy leaves the filters cold at sample 0 and warm at the end -- which
        # breaks the very periodicity the loop point bought us. Process three
        # copies and keep the middle one: its filter and gain state is settled
        # and identical at both edges, so the extracted copy is truly periodic.
        raw = work / "tiled.wav"
        sf.write(str(raw), _tile(loop, 3), rate, format="WAV", subtype="FLOAT")

        # Same phone-speaker chain as the v6 master, minus the atempo stretch:
        # the discovered loop keeps the source's own tempo.
        chain = (
            f"aresample={APP_SAMPLE_RATE},pan=mono|c0=0.707*FL+0.707*FR,"
            "highpass=f=90,lowpass=f=10000,equalizer=f=2800:t=q:w=1:g=2,"
            "acompressor=threshold=0.10:ratio=4:attack=4:release=80:makeup=3,"
            "alimiter=limit=0.78:attack=5:release=50:level=false:latency=true"
        )
        tiled_pcm = work / "tiled_chain.wav"
        run(["ffmpeg", "-hide_banner", "-loglevel", "error", "-y", "-i", str(raw),
             "-af", chain, "-ar", str(APP_SAMPLE_RATE), "-ac", "1",
             "-c:a", "pcm_s16le", str(tiled_pcm)])

        processed, processed_rate = sf.read(str(tiled_pcm), dtype="int16")
        if processed_rate != APP_SAMPLE_RATE:
            raise MasteringError(f"Chain returned {processed_rate} Hz, expected {APP_SAMPLE_RATE}")
        span = round(loop_seconds * APP_SAMPLE_RATE)
        if len(processed) < 2 * span:
            raise MasteringError("Processed tile is shorter than two loop spans")
        middle = processed[span : 2 * span]

        pcm = work / "chain.wav"
        sf.write(str(pcm), middle, APP_SAMPLE_RATE, format="WAV", subtype="PCM_16")

        pending = work / destination.name
        run(["afconvert", str(pcm), str(pending), "-d", "ima4", "-f", "caff"])
        report = validate_v9_audio(pending)
        destination.parent.mkdir(parents=True, exist_ok=True)
        pending.replace(destination)

    report.update(
        {
            "masterer": "pymusiclooper",
            "loopStartSeconds": round(start / rate, 4),
            "loopEndSeconds": round(end / rate, 4),
            "loopSeconds": round(loop_seconds, 4),
            "sourceSeconds": round(source_seconds, 4),
            "loopScore": round(float(pair.score), 4),
            "ladderRung": rung,
            "crossfadeSeconds": CROSSFADE_SECONDS,
        }
    )
    return report


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path)
    parser.add_argument("destination", type=Path)
    parser.add_argument("--min-seconds", type=float, default=MIN_LOOP_SECONDS)
    parser.add_argument("--max-seconds", type=float, default=MAX_LOOP_SECONDS)
    arguments = parser.parse_args()
    report = master_loop_pml(
        arguments.source, arguments.destination,
        arguments.min_seconds, arguments.max_seconds,
    )
    print(json.dumps(report, indent=2))
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except MasteringError as error:
        print(f"ERROR: {error}", file=sys.stderr)
        sys.exit(1)
