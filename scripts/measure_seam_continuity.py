#!/usr/bin/env python3
"""Score how audible a loop's wrap point is, so mastering changes can be compared.

Tile the loop twice, take a spectral-flux curve across the whole thing, and ask
where the flux at the seam sits inside the distribution of *comparable* moments.

Which comparison set is the whole difficulty. Comparing the seam against every
interior frame is wrong and flatters the wrong loops: a correctly discovered
loop wraps onto a downbeat, downbeats carry the largest onsets in most music,
and so a well-formed wrap scores near the 100th percentile purely for landing
where it should. Measured that way a loop whose PyMusicLooper match score was
0.96 came out at the 99.9th percentile -- an artefact, not a defect.

So the comparison set is beat-aligned transitions only, found by beat tracking
the tiled audio. The question becomes "does the wrap look like this song's
other beat boundaries?", which is what a listener actually judges. A percentile
near 50 means the wrap is an unremarkable beat; near 100 means it is the
harshest beat transition in the loop. `interiorBeats` reports how many moments
the percentile was computed against -- below ~8 the number is weak evidence,
and unbeat-trackable material (drones, free time) falls back to all frames with
`beatAligned: false` so it is never silently mixed with the rest.

The report also gives the raw sample step across the wrap, which catches DC
clicks that spectral flux smooths over.

Requires the pymusiclooper venv (numpy/librosa/soundfile):
  .venvs/pml/bin/python scripts/measure_seam_continuity.py LOOP.caf [LOOP.caf ...]
"""

from __future__ import annotations

import argparse
import json
import statistics
import subprocess
import sys
import tempfile
import warnings
from pathlib import Path
from typing import Any

HOP_LENGTH = 512
N_FFT = 2048


def decode(path: Path, work: Path) -> Path:
    """CAF written by afconvert cannot be demuxed by ffmpeg; use afconvert."""
    destination = work / (path.stem + ".wav")
    if path.suffix.lower() == ".caf":
        command = ["afconvert", str(path), str(destination), "-d", "LEI16", "-f", "WAVE"]
    else:
        command = ["ffmpeg", "-hide_banner", "-loglevel", "error", "-y",
                   "-i", str(path), str(destination)]
    result = subprocess.run(command, capture_output=True, text=True)
    if result.returncode != 0:
        raise RuntimeError(f"decode failed for {path}: {(result.stderr or '')[-300:]}")
    return destination


def measure(path: Path) -> dict[str, Any]:
    import librosa
    import numpy as np
    import soundfile as sf

    with tempfile.TemporaryDirectory(prefix="rise-seam-") as temporary:
        audio, rate = sf.read(str(decode(path, Path(temporary))), dtype="float32")
    if audio.ndim > 1:
        audio = audio.mean(axis=1)

    # Two laps, so the frame sequence actually crosses the wrap the way playback
    # does. One lap would only ever show interior transitions.
    tiled = np.concatenate([audio, audio])
    spectrogram = np.abs(librosa.stft(tiled, n_fft=N_FFT, hop_length=HOP_LENGTH))
    # Half-wave rectified spectral flux: only energy *arriving* marks an onset.
    flux = np.sum(np.maximum(0.0, np.diff(spectrogram, axis=1)), axis=0)

    seam_frame = len(audio) // HOP_LENGTH
    # The wrap smears across the frames whose window straddles it.
    span = max(1, N_FFT // HOP_LENGTH)
    low, high = max(0, seam_frame - 1), min(len(flux), seam_frame + span)
    seam_flux = float(np.max(flux[low:high]))

    # Beat-aligned comparison set: the wrap judged against this song's own beat
    # boundaries. Excludes the frames the wrap itself occupies.
    beat_aligned = True
    try:
        _, beats = librosa.beat.beat_track(y=tiled, sr=rate, hop_length=HOP_LENGTH)
        interior = np.array(
            [flux[b] for b in beats if 0 <= b < len(flux) and not (low <= b < high)],
            dtype=np.float32,
        )
    except Exception:
        interior = np.array([], dtype=np.float32)

    # Drones and free-time material defeat beat tracking; fall back rather than
    # report a percentile computed against three beats.
    if len(interior) < 8:
        beat_aligned = False
        interior = np.concatenate([flux[:low], flux[high:]])

    percentile = float((interior < seam_flux).sum() / len(interior) * 100.0)

    return {
        "file": path.name,
        "durationSeconds": round(len(audio) / rate, 3),
        "beatAligned": beat_aligned,
        "interiorBeats": int(len(interior)),
        "seamFluxPercentile": round(percentile, 1),
        "seamFlux": round(seam_flux, 3),
        "medianInteriorFlux": round(float(np.median(interior)), 3),
        "seamFluxRatio": round(seam_flux / max(float(np.median(interior)), 1e-9), 2),
        "wrapSampleStep": round(float(abs(audio[0] - audio[-1])), 5),
    }


def main() -> int:
    warnings.filterwarnings("ignore")
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("loops", nargs="+", type=Path)
    parser.add_argument("--json", action="store_true", help="emit raw JSON records")
    arguments = parser.parse_args()

    records = []
    for path in arguments.loops:
        try:
            records.append(measure(path))
        except Exception as error:  # keep going; one bad file should not stop a sweep
            print(f"ERROR {path.name}: {error}", file=sys.stderr)

    if arguments.json:
        print(json.dumps(records, indent=2))
        return 0

    print(f"{'file':<44} {'secs':>6} {'beats':>6} {'seam %ile':>10} {'x median':>9} {'step':>8}")
    for record in records:
        print(
            f"{record['file']:<44} {record['durationSeconds']:>6.2f} "
            f"{record['interiorBeats']:>6}{'' if record['beatAligned'] else '*'} "
            f"{record['seamFluxPercentile']:>10.1f} {record['seamFluxRatio']:>9.2f} "
            f"{record['wrapSampleStep']:>8.5f}"
        )
    if len(records) > 1:
        percentiles = [r["seamFluxPercentile"] for r in records]
        fallbacks = sum(1 for r in records if not r["beatAligned"])
        print(
            f"\n{len(records)} loops · median seam percentile "
            f"{statistics.median(percentiles):.1f} · "
            f"worst {max(percentiles):.1f} · "
            f"{sum(1 for p in percentiles if p >= 90.0)} at/above the 90th percentile"
        )
        if fallbacks:
            print(
                f"* {fallbacks} loop(s) were not beat-trackable and fell back to "
                "all-frame comparison; their percentiles are not comparable."
            )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
