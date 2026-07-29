#!/usr/bin/env python3
"""Emit the mechanical skeleton of the v9 allocation: 64 slots per tier.

Run 1 of v9 let the authors choose everything, and the set collapsed: one comic
mechanism per tier, 62/64 songs with four lyric lines, no refrains anywhere, and
all 320 `key` fields claiming cadence was impossible. Those are distribution
failures, so v9 run 2 fixes them by construction — this script hands every slot a
pre-assigned comic mechanism, emotional register, lyric shape, cadence duty and
seam-voice duty, spread evenly across each batch of 16.

What the script decides (never negotiable downstream): id, meter, bars, bpm,
vocalistGender, batch, mechanism, register, lyricLines, refrain, rhyme,
resolvesAcrossWrap, voiceAcrossWrap.
What an allocation author adds later: genre, artist, premiseSeed.

Loop length L = bars x beatsPerBar x 60 / bpm is held inside [20.0, 30.0) for
every slot, and tempos stay inside a per-tier band so the escalation ladder is
audible before a note is written.

  scripts/build_allocation_v9.py [--out scratch_data/music_v9/allocation]
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

PROJECT_ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(PROJECT_ROOT / "scripts"))
from loop_bar_math import beats_per_bar  # noqa: E402

TIERS = ("soothing", "relaxing", "motivating", "energizing", "abrasive")
SONGS_PER_TIER = 64
BATCH_SIZE = 16
MIN_LOOP_SECONDS = 20.0
MAX_LOOP_SECONDS = 30.0

# Tempo band per tier. The bands overlap slightly — the ladder is carried by
# arrangement and lyric heat too — but the centre of mass climbs.
# Soothing starts at 68 rather than 58: below that it stops being the gentlest
# way to wake up and becomes music to fall asleep to, which is the opposite job.
TEMPO_BANDS = {
    "soothing": (68.0, 92.0),
    "relaxing": (68.0, 100.0),
    "motivating": (92.0, 128.0),
    "energizing": (120.0, 162.0),
    "abrasive": (138.0, 190.0),
}

# Meter menu per tier, cycled so odd meters land at a steady low rate rather
# than clustering. 6/8 counts 2 dotted-quarter pulses per bar.
METER_CYCLES = {
    "soothing": ("4/4", "4/4", "3/4", "4/4", "6/8", "4/4", "5/4", "4/4"),
    "relaxing": ("4/4", "4/4", "6/8", "4/4", "3/4", "4/4", "4/4", "5/4"),
    "motivating": ("4/4", "4/4", "4/4", "3/4", "4/4", "4/4", "7/8", "4/4"),
    "energizing": ("4/4", "4/4", "4/4", "4/4", "7/8", "4/4", "4/4", "6/8"),
    "abrasive": ("4/4", "4/4", "4/4", "5/4", "4/4", "4/4", "4/4", "7/8"),
}

# The taxonomy the run-1 revision brief arrived at, plus the caps it imposed.
# Ordered so that consecutive slots — which land in the same batch — differ.
MECHANISMS = (
    "straight sincerity: no joke at all, genuine tenderness or awe played completely straight",
    "refusal / resistance: the singer will not get up and argues the case",
    "unreliable narrator: the singer is plainly wrong about what is happening",
    "overheard fragment: one side of a conversation, we infer the rest",
    "escalating list: a catalogue that gets progressively unhinged",
    "understatement: catastrophe described as mild inconvenience",
    "nostalgia / elegy: this morning measured against a former one",
    "superstition / folk ritual: a bargain struck with the day",
    "physical comedy: the body as slapstick, staged in sound",
    "menace played warm: something affectionate and slightly threatening",
    "anticlimax: a build to nothing whatsoever",
    "inanimate POV: the room, the weather or an appliance narrates",
    "misapplied grandeur: a small act narrated as epic or institutional",
    "mock-officialdom: paperwork, courts, clerks, policy",
)
# Slots per batch of 16 for the two mechanisms that ran away in run 1.
CAPPED = {"misapplied grandeur": 2, "mock-officialdom": 1}

# Some mechanisms contradict a tier's brief. Soothing is warm first light and
# an appetite for the day, so a song built on refusing to get up cannot exist
# there however well it is written.
MECHANISM_OVERRIDES = {
    "soothing": {
        "refusal / resistance": (
            "invitation: the singer coaxes someone or something else into the morning"
        ),
    },
}

REGISTERS = {
    # Soothing is the gentlest rung of a wake-up ladder, not sleep music: warm
    # first light and an appetite for the day, never inertia or drowsiness.
    "soothing": ("optimism", "warmth", "quiet joy", "gratitude", "awe",
                 "tenderness", "anticipation", "gentle resolve"),
    "relaxing": ("ease", "irony", "contentment", "drift", "wry patience",
                 "gentle absurdity", "nostalgia", "resolve"),
    "motivating": ("resolve", "sincere joy", "dread held down", "comic ceremony",
                   "tenderness", "impatience", "gallows humour", "defiance"),
    "energizing": ("glee", "urgency", "mania", "triumph", "panic played funny",
                   "swagger", "exasperation", "sincere joy"),
    "abrasive": ("fury", "contempt", "mania", "gallows humour", "menace",
                 "exhaustion turned mean", "glee", "grievance"),
}

# Lyric shape per batch of 16: 4 threes, 8 fours, 4 fives (run 1 was 62/64 fours).
LINE_COUNT_CYCLE = (3, 4, 5, 4, 3, 4, 4, 5, 4, 3, 4, 5, 4, 4, 3, 5)
# Duty flags, positioned so each batch of 16 gets the quota the brief demands.
REFRAIN_SLOTS = (0, 2, 4, 6, 8, 10, 13)          # 7 of 16
RHYME_SLOTS = (1, 3, 7, 9, 12, 15)               # 6 of 16
RESOLVES_SLOTS = (0, 3, 5, 8, 11, 14)            # 6 of 16 cadence genuinely
VOICE_ACROSS_WRAP_SLOTS = (2, 6, 9, 15)          # 4 of 16 sing across the seam


def tempo_for(tier: str, index: int) -> float:
    """Spread tempos across the tier band without clustering.

    Walking the band in golden-ratio steps keeps neighbouring slots — which
    share a batch — far apart in tempo while still covering the band evenly.
    """
    low, high = TEMPO_BANDS[tier]
    position = (index * 0.6180339887498949) % 1.0
    return low + (high - low) * position


def target_length_for(index: int) -> float:
    """Spread loop lengths across the window, again in golden-ratio steps."""
    position = ((index + 7) * 0.6180339887498949) % 1.0
    return 20.6 + (29.4 - 20.6) * position


def fit_bars_and_bpm(meter: str, bpm: float, target: float) -> tuple[int, float]:
    """Choose a whole bar count near `target` seconds, then trim bpm to fit.

    Bars must be an integer, so the requested length is never exactly available.
    Rather than accept whatever length falls out, nudge bpm — a fraction of a
    beat per minute — so the loop lands where the spread wanted it.
    """
    per_bar = beats_per_bar(meter)
    bars = max(4, round(target * bpm / (60.0 * per_bar)))
    length = bars * per_bar * 60.0 / bpm
    if not (MIN_LOOP_SECONDS + 0.4 <= length <= MAX_LOOP_SECONDS - 0.4):
        length = min(max(target, 20.6), 29.4)
        bpm = bars * per_bar * 60.0 / length
    return bars, round(bpm, 2)


def mechanism_for(slot_in_batch: int, batch: int, tier: str) -> str:
    """Assign mechanisms so a batch spans many and no capped one runs away."""
    # Offset per batch so the four batches of a tier do not share an ordering.
    ordered = MECHANISMS[batch - 1 :] + MECHANISMS[: batch - 1]
    choice = ordered[slot_in_batch % len(ordered)]
    label = choice.split(":")[0]
    if slot_in_batch >= len(ordered) and label in CAPPED:
        # The second lap through the list would exceed a capped mechanism's
        # quota; hand the slot to the uncapped mechanism at the same offset.
        choice = ordered[slot_in_batch % 11]
    return MECHANISM_OVERRIDES.get(tier, {}).get(choice.split(":")[0], choice)


def build_tier(tier: str) -> list[dict]:
    slots = []
    meters = METER_CYCLES[tier]
    registers = REGISTERS[tier]
    for index in range(SONGS_PER_TIER):
        batch = index // BATCH_SIZE + 1
        slot_in_batch = index % BATCH_SIZE
        meter = meters[index % len(meters)]
        bars, bpm = fit_bars_and_bpm(meter, tempo_for(tier, index), target_length_for(index))
        length = bars * beats_per_bar(meter) * 60.0 / bpm
        if not (MIN_LOOP_SECONDS <= length < MAX_LOOP_SECONDS):
            raise SystemExit(f"{tier}_{index + 1:03d}: L={length:.2f}s outside the window")
        slots.append(
            {
                "id": f"{tier}_{index + 1:03d}",
                "batch": batch,
                "meter": meter,
                "bars": bars,
                "bpm": bpm,
                "loopSeconds": round(length, 2),
                # Alternating within a batch, so every batch is 8 female / 8 male.
                "vocalistGender": "female" if (index % 2 == 0) else "male",
                "mechanism": mechanism_for(slot_in_batch, batch, tier),
                "register": registers[(index * 3 + batch) % len(registers)],
                "lyricLines": LINE_COUNT_CYCLE[slot_in_batch],
                "refrain": slot_in_batch in REFRAIN_SLOTS,
                "rhyme": slot_in_batch in RHYME_SLOTS,
                "resolvesAcrossWrap": slot_in_batch in RESOLVES_SLOTS,
                "voiceAcrossWrap": slot_in_batch in VOICE_ACROSS_WRAP_SLOTS,
                "genre": "",
                "artist": "",
                "premiseSeed": "",
            }
        )
    return slots


def report(tier: str, slots: list[dict]) -> None:
    from collections import Counter

    lengths = [s["loopSeconds"] for s in slots]
    tempos = [s["bpm"] for s in slots]
    print(
        f"{tier}: {len(slots)} slots · L {min(lengths):.1f}-{max(lengths):.1f}s · "
        f"bpm {min(tempos):.0f}-{max(tempos):.0f} · "
        f"{Counter(s['vocalistGender'] for s in slots)['female']}F/"
        f"{Counter(s['vocalistGender'] for s in slots)['male']}M · "
        f"meters {dict(Counter(s['meter'] for s in slots))}"
    )
    for batch in (1, 2, 3, 4):
        group = [s for s in slots if s["batch"] == batch]
        mechanisms = Counter(s["mechanism"].split(":")[0] for s in group)
        worst = mechanisms.most_common(1)[0]
        print(
            f"  batch{batch}: {len(mechanisms)} mechanisms (max {worst[1]}x {worst[0]}) · "
            f"lines {dict(Counter(s['lyricLines'] for s in group))} · "
            f"refrain {sum(s['refrain'] for s in group)} · rhyme {sum(s['rhyme'] for s in group)} · "
            f"cadence {sum(s['resolvesAcrossWrap'] for s in group)} · "
            f"seamvoice {sum(s['voiceAcrossWrap'] for s in group)}"
        )


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--out", type=Path, default=PROJECT_ROOT / "scratch_data" / "music_v9" / "allocation"
    )
    parser.add_argument(
        "--tier", action="append", default=[], choices=TIERS,
        help="rebuild only these tiers; the others keep their filled-in briefs",
    )
    arguments = parser.parse_args()
    arguments.out.mkdir(parents=True, exist_ok=True)
    for tier in (arguments.tier or TIERS):
        slots = build_tier(tier)
        report(tier, slots)
        (arguments.out / f"{tier}.json").write_text(
            json.dumps(slots, indent=2, ensure_ascii=False) + "\n", encoding="utf-8"
        )
    print(f"Wrote {len(arguments.tier or TIERS)} allocation file(s) to {arguments.out}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
