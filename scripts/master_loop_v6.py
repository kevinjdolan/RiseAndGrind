#!/usr/bin/env python3
"""Beat-maintained mastering of a generated source into an exact 29 s loop CAF.

The v4 chain cut at an arbitrary 29.000 s, so its seam crossfade blended two
different beat phases. This chain keeps the beat across the seam:

1. Verify tempo: estimate the source's actual BPM near the planned BPM from an
   onset-energy autocorrelation (falls back to the planned BPM for beatless
   material, where bar phase is moot).
2. Cut the loop at a WHOLE-BAR boundary: L = bars x beats x 60/bpm_actual.
3. Bridge the seam exactly like the proven v4 graph — body starts one beat in,
   and the bridge crossfades the bar AFTER the loop point into the loop head —
   but at a bar-aligned point, so the crossfade blends two downbeats in phase.
4. Micro time-stretch (atempo, pitch-preserving) by 29.000/L — planned tempos
   from loop_bar_math keep this under 0.6 percent, inaudible.
5. Apply the phone-speaker chain, encode mono 22.05 kHz IMA4 CAF, validate
   duration/samples/size exactly like the shipped library.

Usage:
  master_loop_v6.py IN.mp3 OUT.caf --bpm 99.31 --meter 4/4 --bars 12
"""

from __future__ import annotations

import argparse
import json
import math
import struct
import subprocess
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from generate_music_library_v4 import (  # noqa: E402
    APP_SAMPLE_COUNT,
    APP_SAMPLE_RATE,
    TRACK_SECONDS,
    GenerationError,
    probe_audio,
    run,
    validate_app_audio,
)
from loop_bar_math import beats_per_bar, fit_error  # noqa: E402

MAX_STRETCH = 0.02
ANALYSIS_RATE = 22_050
HOP = 512


def decode_mono(source: Path, sample_rate: int) -> list[float]:
    """Decode a source to mono float samples via ffmpeg."""
    raw = subprocess.run(
        ["ffmpeg", "-v", "error", "-i", str(source), "-f", "f32le", "-ac", "1",
         "-ar", str(sample_rate), "-"],
        capture_output=True, check=True,
    ).stdout
    count = len(raw) // 4
    return list(struct.unpack(f"<{count}f", raw[: count * 4]))


def onset_envelope(samples: list[float]) -> list[float]:
    """Half-wave-rectified frame-energy difference — a cheap onset strength curve."""
    energies = []
    for start in range(0, len(samples) - HOP, HOP):
        frame = samples[start : start + HOP]
        energies.append(math.sqrt(sum(x * x for x in frame) / HOP))
    envelope = [0.0]
    for previous, current in zip(energies, energies[1:]):
        envelope.append(max(0.0, current - previous))
    return envelope


def estimate_bpm(samples: list[float], planned_bpm: float) -> tuple[float, float]:
    """Return (bpm, confidence) by autocorrelating onsets near the planned tempo."""
    envelope = onset_envelope(samples)
    if not any(envelope):
        return planned_bpm, 0.0
    frame_rate = ANALYSIS_RATE / HOP
    best_bpm, best_score = planned_bpm, -1.0
    scores = []
    candidate = planned_bpm * 0.92
    while candidate <= planned_bpm * 1.08:
        lag = frame_rate * 60.0 / candidate
        score = 0.0
        for multiple in (1, 2):
            shift = int(round(lag * multiple))
            if shift >= len(envelope):
                continue
            score += sum(
                envelope[i] * envelope[i + shift]
                for i in range(len(envelope) - shift)
            ) / (multiple * (len(envelope) - shift))
        scores.append(score)
        if score > best_score:
            best_bpm, best_score = candidate, score
        candidate *= 1.002
    mean_score = sum(scores) / len(scores)
    confidence = 0.0 if mean_score <= 0 else (best_score - mean_score) / mean_score
    return best_bpm, confidence


def master_loop_v6(
    source: Path,
    destination: Path,
    planned_bpm: float,
    meter: str,
    bars: int,
    verify_tempo: bool = True,
) -> dict:
    """Master one source into an exact 29 s bar-aligned loop CAF."""
    if abs(fit_error(planned_bpm, meter, bars)) > 0.02:
        raise GenerationError(
            f"Planned {planned_bpm} BPM {meter} x {bars} bars is not near {TRACK_SECONDS}s"
        )
    metadata = probe_audio(source)
    bpm, confidence = planned_bpm, 0.0
    if verify_tempo:
        samples = decode_mono(source, ANALYSIS_RATE)
        estimated, confidence = estimate_bpm(samples, planned_bpm)
        if confidence >= 0.15:
            bpm = estimated
    beat_seconds = 60.0 / bpm
    loop_seconds = bars * beats_per_bar(meter) * beat_seconds
    if loop_seconds > metadata["duration"] - 0.05:
        raise GenerationError(
            f"Loop of {loop_seconds:.2f}s does not fit in a "
            f"{metadata['duration']:.2f}s source"
        )
    stretch = TRACK_SECONDS / loop_seconds
    if abs(stretch - 1.0) > MAX_STRETCH:
        raise GenerationError(
            f"Stretch {stretch:.4f} exceeds {MAX_STRETCH:.0%}; "
            "regenerate or adjust bars/bpm"
        )

    crossfade_seconds = min(0.5, beat_seconds)
    loop_samples = round(loop_seconds * APP_SAMPLE_RATE)
    crossfade_samples = round(crossfade_seconds * APP_SAMPLE_RATE)
    bridge_end = loop_samples + crossfade_samples
    source_samples = round(metadata["duration"] * APP_SAMPLE_RATE)

    with tempfile.TemporaryDirectory(prefix="rise-v6-master-") as temporary:
        work = Path(temporary)
        pcm = work / "loop.wav"
        prepare = (
            f"aresample={APP_SAMPLE_RATE},pan=mono|c0=0.707*FL+0.707*FR,"
            f"apad=whole_len={source_samples},asetpts=N/SR/TB"
        )
        filter_graph = (
            f"[0:a]{prepare},asplit=3[body_source][tail_source][head_source];"
            f"[body_source]atrim=start_sample={crossfade_samples}:"
            f"end_sample={loop_samples},asetpts=N/SR/TB[body];"
            f"[tail_source]atrim=start_sample={loop_samples}:"
            f"end_sample={bridge_end},asetpts=N/SR/TB[tail];"
            f"[head_source]atrim=start_sample=0:end_sample={crossfade_samples},"
            "asetpts=N/SR/TB[head];"
            f"[tail][head]acrossfade=d={crossfade_seconds:.6f}:c1=tri:c2=tri[bridge];"
            f"[body][bridge]concat=n=2:v=0:a=1,atrim=end_sample={loop_samples},"
            f"asetpts=N/SR/TB,atempo={stretch:.8f},"
            "highpass=f=90,lowpass=f=10000,equalizer=f=2800:t=q:w=1:g=2,"
            "acompressor=threshold=0.10:ratio=4:attack=4:release=80:makeup=3,"
            "alimiter=limit=0.78:attack=5:release=50:level=false:latency=true,"
            f"apad=whole_len={APP_SAMPLE_COUNT},atrim=end_sample={APP_SAMPLE_COUNT},"
            "asetpts=N/SR/TB[output]"
        )
        run(
            ["ffmpeg", "-hide_banner", "-loglevel", "error", "-y", "-i", str(source),
             "-filter_complex", filter_graph, "-map", "[output]",
             "-ar", str(APP_SAMPLE_RATE), "-ac", "1", "-c:a", "pcm_s16le", str(pcm)]
        )
        pending = work / destination.name
        run(["afconvert", str(pcm), str(pending), "-d", "ima4", "-f", "caff"])
        report = validate_app_audio(pending)
        destination.parent.mkdir(parents=True, exist_ok=True)
        pending.replace(destination)
    report.update(
        {
            "plannedBpm": planned_bpm,
            "usedBpm": round(bpm, 3),
            "tempoConfidence": round(confidence, 3),
            "bars": bars,
            "meter": meter,
            "loopSeconds": round(loop_seconds, 4),
            "stretch": round(stretch, 6),
            "crossfadeSeconds": round(crossfade_seconds, 4),
        }
    )
    return report


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path)
    parser.add_argument("destination", type=Path)
    parser.add_argument("--bpm", type=float, required=True)
    parser.add_argument("--meter", default="4/4")
    parser.add_argument("--bars", type=int, required=True)
    parser.add_argument("--no-verify-tempo", action="store_true")
    arguments = parser.parse_args()
    report = master_loop_v6(
        arguments.source,
        arguments.destination,
        arguments.bpm,
        arguments.meter,
        arguments.bars,
        verify_tempo=not arguments.no_verify_tempo,
    )
    print(json.dumps(report, indent=2))
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except GenerationError as error:
        print(f"ERROR: {error}", file=sys.stderr)
        sys.exit(1)
