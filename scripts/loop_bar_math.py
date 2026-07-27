#!/usr/bin/env python3
"""Bar-math helper for 29-second seamless loops.

List tempos whose whole-bar counts fill the target duration, or check a plan's
bpm/meter/bars entries. A plan tempo is valid when bars x beats x 60/bpm lands
within +/-0.6 percent of the target; mastering micro-stretches the remainder.
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

TARGET_SECONDS = 29.0
TOLERANCE = 0.006


def beats_per_bar(meter: str) -> int:
    numerator, _, denominator = meter.partition("/")
    beats = int(numerator)
    if denominator == "8" and beats % 3 == 0:
        return beats // 3  # compound meters: count dotted-quarter pulses
    return beats


def exact_bpm(bars: int, meter: str, target: float = TARGET_SECONDS) -> float:
    return bars * beats_per_bar(meter) * 60.0 / target


def fit_error(bpm: float, meter: str, bars: int, target: float = TARGET_SECONDS) -> float:
    loop_seconds = bars * beats_per_bar(meter) * 60.0 / bpm
    return loop_seconds / target - 1.0


def print_table(meter: str) -> None:
    print(f"Whole-bar fits for {TARGET_SECONDS:.1f}s in {meter} "
          f"(compose at a standard tempo within {TOLERANCE:.1%} of the exact fit):")
    for bars in range(6, 32):
        bpm = exact_bpm(bars, meter)
        if 55 <= bpm <= 220:
            print(f"  {bars:2d} bars -> {bpm:7.2f} BPM exact")


def check_plan(path: Path) -> int:
    plan = json.loads(path.read_text(encoding="utf-8"))
    songs = plan if isinstance(plan, list) else [s for tier in plan.values() for s in tier]
    failures = 0
    for song in songs:
        error = fit_error(float(song["bpm"]), song["meter"], int(song["bars"]))
        status = "ok" if abs(error) <= TOLERANCE else "FAIL"
        if status == "FAIL":
            failures += 1
            print(f"{song['id']}: {song['bpm']} BPM {song['meter']} x {song['bars']} bars "
                  f"-> {error:+.2%} from {TARGET_SECONDS}s ({status})")
    print(f"{len(songs)} songs checked, {failures} outside +/-{TOLERANCE:.1%}")
    return 1 if failures else 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--meter", default="4/4")
    parser.add_argument("--check", type=Path, metavar="PLAN_JSON")
    arguments = parser.parse_args()
    if arguments.check:
        return check_plan(arguments.check)
    print_table(arguments.meter)
    return 0


if __name__ == "__main__":
    sys.exit(main())
