#!/usr/bin/env python3
"""Merge, validate, and render the v9 song plan (64 songs per tier, 320 total).

Reads scratch_data/music_v9/plan_vN/{tier}.json, runs the mechanical checks
from the compose-looping-alarm-songs skill, and writes plan_vN.json plus a
reviewer-facing plan_vN.yaml.

Two things differ from the v6/v7 builders:

* Loop length is a window, not a constant. v9 masters with PyMusicLooper, which
  discovers the loop empirically instead of stretching to 29.000 s, so a song
  is valid when bars x beats x 60/bpm lands anywhere in [20, 30) seconds. Each
  song's own nominal length is what its structure timestamps are checked
  against.
* Variety budgets scale with tier size. At 64 songs per tier the v7 budget of
  one motif use per tier is unachievable, so budgets are proportional -- still
  tight enough to force range, loose enough to be satisfiable.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from collections import Counter
from pathlib import Path

PROJECT_ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(PROJECT_ROOT / "scripts"))
from loop_bar_math import beats_per_bar  # noqa: E402
from music_catalog_v4 import VULGARITY_WEIGHTS  # noqa: E402

TIERS = ["soothing", "relaxing", "motivating", "energizing", "abrasive"]
SONGS_PER_TIER = 64
MIN_LOOP_SECONDS = 20.0
MAX_LOOP_SECONDS = 30.0  # exclusive

REQUIRED_KEYS = {
    "id", "title", "artist", "genre", "vocalist", "bpm", "meter", "bars",
    "key", "instrumentation", "rhythm", "structure", "loopSeam", "lyrics",
    "premise",
}
# Per tier, at 64 songs. Tight enough to force range across the set.
MOTIF_BUDGETS = {
    "coffee": (r"\bcoffee|espresso|latte\b", 3),
    "inbox/email": (r"\binbox|email|unread\b", 3),
    "meetings": (r"\bmeeting|standup\b", 3),
    "calendar": (r"\bcalendar\b", 2),
    "snooze": (r"\bsnooze\b", 4),
    "alarm": (r"\balarm\b", 4),
    "grind/hustle": (r"\bgrind|hustle\b", 4),
    "sunrise-personification": (r"\bsun\b.*\b(crew|creditor|collector|showing|arrived)\b", 2),
}
MAX_OPENING_WORD_REUSE = 2
MAX_EXPLICIT_WAKE_FRACTION = 0.15  # of the whole set
# Share of the loop that may pass without a voice before the wrap.
MAX_VOICELESS_TAIL = 0.25
VOCAL_MOMENT = re.compile(r"line \d|vocal|sings|voice enters|refrain|hook", re.IGNORECASE)
VULGARITY_LIMITS = {"soothing": 0, "relaxing": 0, "motivating": 2, "energizing": 6, "abrasive": 24}
BANNED = {"bitch", "cunt", "slut", "whore", "pussy", "dick", "asshole"}


def vulgarity(song: dict) -> int:
    text = " ".join([song["title"], *song["lyrics"]]).lower()
    return sum(VULGARITY_WEIGHTS.get(w, 0) for w in re.split(r"[^a-z]+", text))


def loop_seconds(song: dict) -> float:
    return int(song["bars"]) * beats_per_bar(song["meter"]) * 60.0 / float(song["bpm"])


def load_allocation() -> dict[str, dict]:
    """Index every allocation slot by id, or return {} if none is present."""
    directory = PROJECT_ROOT / "scratch_data" / "music_v9" / "allocation"
    slots: dict[str, dict] = {}
    for tier in TIERS:
        path = directory / f"{tier}.json"
        if path.is_file():
            for slot in json.loads(path.read_text(encoding="utf-8")):
                slots[slot["id"]] = slot
    return slots


def validate_against_allocation(songs: list[dict], slots: dict[str, dict]) -> list[str]:
    """Check each song still matches the slot it was authored against.

    The allocation is what guarantees the set's spread — mechanisms, lyric
    shapes, cadence duty. An author who quietly changes bpm or drops a lyric
    line breaks a distribution nobody would notice song by song.
    """
    problems: list[str] = []
    for song in songs:
        slot = slots.get(str(song.get("id")))
        if slot is None:
            problems.append(f"{song.get('id', '?')}: no allocation slot")
            continue
        for key in ("artist", "genre", "meter", "bars", "bpm"):
            if song.get(key) != slot[key]:
                problems.append(
                    f"{song['id']}: {key} is {song.get(key)!r}, allocated {slot[key]!r}"
                )
        if abs(loop_seconds(song) - slot["loopSeconds"]) > 0.05:
            problems.append(
                f"{song['id']}: loop is {loop_seconds(song):.2f}s, "
                f"allocated {slot['loopSeconds']:.2f}s"
            )
        if len(song.get("lyrics", [])) != slot["lyricLines"]:
            problems.append(
                f"{song['id']}: {len(song.get('lyrics', []))} lyric lines, "
                f"allocated {slot['lyricLines']}"
            )
        gender = str(song.get("vocalist", "")).split(";")[0].strip().lower()
        if gender != slot["vocalistGender"]:
            problems.append(
                f"{song['id']}: vocalist is {gender!r}, allocated {slot['vocalistGender']!r}"
            )
    return problems


def validate(songs: list[dict]) -> list[str]:
    problems: list[str] = []
    slots = load_allocation()
    if slots:
        problems.extend(validate_against_allocation(songs, slots))
    for unique_key in ("id", "title", "artist"):
        counts = Counter(str(s[unique_key]).lower() for s in songs)
        for value, count in counts.items():
            if count > 1:
                problems.append(f"duplicate {unique_key}: {value} ({count}x)")

    for tier in TIERS:
        tier_songs = [s for s in songs if str(s.get("id", "")).startswith(tier)]
        if len(tier_songs) != SONGS_PER_TIER:
            problems.append(
                f"{tier}: expected {SONGS_PER_TIER} songs, found {len(tier_songs)}"
            )
        if not tier_songs:
            continue

        openers = Counter(
            s["lyrics"][0].split()[0].lower().strip(",:;")
            for s in tier_songs if s.get("lyrics")
        )
        for word, count in openers.items():
            if count > MAX_OPENING_WORD_REUSE:
                problems.append(
                    f"{tier}: opening word '{word}' used {count}x "
                    f"(max {MAX_OPENING_WORD_REUSE})"
                )
        for motif, (pattern, budget) in MOTIF_BUDGETS.items():
            hits = [
                s["id"] for s in tier_songs
                if re.search(pattern, " ".join(s["lyrics"] + [s["premise"]]).lower())
            ]
            if len(hits) > budget:
                problems.append(
                    f"{tier}: motif '{motif}' used {len(hits)}x over budget {budget}: "
                    f"{hits[:budget + 3]}"
                )
        genders = Counter(s["vocalist"].split(";")[0].strip().lower() for s in tier_songs)
        half = SONGS_PER_TIER // 2
        if abs(genders.get("female", 0) - half) > 4 or abs(genders.get("male", 0) - half) > 4:
            problems.append(
                f"{tier}: vocalist split {dict(genders)}, expected about {half}/{half}"
            )
        genres = Counter(s["genre"].strip().lower() for s in tier_songs)
        for genre, count in genres.items():
            if count > 2:
                problems.append(f"{tier}: genre '{genre}' repeated {count}x (max 2)")

    for s in songs:
        label = s.get("id", "?")
        missing = REQUIRED_KEYS - set(s)
        if missing:
            problems.append(f"{label}: missing keys {sorted(missing)}")
            continue

        length = loop_seconds(s)
        if not (MIN_LOOP_SECONDS <= length < MAX_LOOP_SECONDS):
            problems.append(
                f"{label}: loop is {length:.2f}s from {s['bpm']} BPM {s['meter']} x "
                f"{s['bars']} bars, outside [{MIN_LOOP_SECONDS}, {MAX_LOOP_SECONDS})"
            )
        if not (3 <= len(s["lyrics"]) <= 5):
            problems.append(f"{label}: {len(s['lyrics'])} lyric lines, expected 3-5")
        for line in s["lyrics"]:
            words = len(line.split())
            if not (3 <= words <= 10):
                problems.append(f"{label}: lyric line '{line[:40]}' has {words} words")
        text = " ".join(s["lyrics"] + [s["title"]]).lower()
        for banned in BANNED:
            if re.search(rf"\b{banned}\b", text):
                problems.append(f"{label}: banned word '{banned}'")
        tier = str(s["id"]).split("_")[0]
        score = vulgarity(s)
        if score > VULGARITY_LIMITS.get(tier, 0):
            problems.append(f"{label}: vulgarity {score} over {tier} limit")

        times = []
        for moment in s["structure"]:
            match = re.match(r"^(\d+(?:\.\d+)?)\s", moment)
            if not match:
                problems.append(f"{label}: structure moment lacks timestamp: {moment[:40]}")
                continue
            times.append(float(match.group(1)))
        if times != sorted(times):
            problems.append(f"{label}: structure timestamps not monotonic")
        if times and times[-1] > length + 0.05:
            problems.append(
                f"{label}: structure runs to {times[-1]:.1f}s past its {length:.1f}s loop"
            )
        # Run 1 left a voiceless hole centred on the wrap in 30-62% of every
        # loop, which reads as an outro. The tail after the last sung moment is
        # what matters, not the tail after the last moment of any kind.
        sung = [
            time
            for time, moment in zip(times, s["structure"])
            if VOCAL_MOMENT.search(moment)
        ]
        if not sung:
            problems.append(f"{label}: no structure moment names a vocal entry")
        elif (length - max(sung)) / length > MAX_VOICELESS_TAIL:
            problems.append(
                f"{label}: voiceless tail {(length - max(sung)) / length:.0%} of the "
                f"{length:.1f}s loop (max {MAX_VOICELESS_TAIL:.0%})"
            )
        if not re.search(r"=\s*0\.0", " ".join(s["structure"])):
            problems.append(f"{label}: no explicit wrap moment (e.g. '24.0 = 0.0') in structure")
        if len(s["structure"]) < 6:
            problems.append(f"{label}: structure has under 6 moments")

    explicit = [
        s["id"] for s in songs
        if re.search(
            r"\b(wake up|get up|feet on|on the floor|stand up)\b",
            " ".join(s["lyrics"]).lower(),
        )
    ]
    if songs and len(explicit) > MAX_EXPLICIT_WAKE_FRACTION * len(songs):
        problems.append(
            f"explicit wake commands in {len(explicit)}/{len(songs)} songs, over "
            f"{MAX_EXPLICIT_WAKE_FRACTION:.0%}"
        )
    return problems


def yaml_quote(value: str) -> str:
    escaped = str(value).replace("\\", "\\\\").replace('"', '\\"')
    return f'"{escaped}"'


def emit_yaml(songs: list[dict]) -> str:
    lines = [
        f"# Rise & Grind music plan v9 — {len(songs)} loop-first songs "
        f"({SONGS_PER_TIER} per tier).",
        "# Composed under .claude/skills/compose-looping-alarm-songs.",
        f"# Loop window {MIN_LOOP_SECONDS:.0f}-{MAX_LOOP_SECONDS:.0f}s; "
        "mastered by PyMusicLooper discovery (scripts/master_loop_pml.py).",
        "",
    ]
    for tier in TIERS:
        lines.append(f"{tier}:")
        for s in (x for x in songs if str(x["id"]).startswith(tier)):
            lines.append(f"  - id: {s['id']}")
            for key in ("title", "artist", "genre", "vocalist"):
                lines.append(f"    {key}: {yaml_quote(s[key])}")
            lines.append(f"    bpm: {s['bpm']}")
            lines.append(f"    meter: {yaml_quote(s['meter'])}")
            lines.append(f"    bars: {s['bars']}")
            lines.append(f"    loopSeconds: {loop_seconds(s):.2f}")
            for key in ("key", "instrumentation", "rhythm"):
                lines.append(f"    {key}: {yaml_quote(s[key])}")
            lines.append("    structure:")
            for moment in s["structure"]:
                lines.append(f"      - {yaml_quote(moment)}")
            lines.append(f"    loopSeam: {yaml_quote(s['loopSeam'])}")
            lines.append("    lyrics:")
            for line in s["lyrics"]:
                lines.append(f"      - {yaml_quote(line)}")
            lines.append(f"    premise: {yaml_quote(s['premise'])}")
        lines.append("")
    return "\n".join(lines)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("version", help="plan version directory name, e.g. plan_v1")
    parser.add_argument("--report-only", action="store_true")
    parser.add_argument("--partial", action="store_true",
                        help="skip the per-tier count check (for in-progress authoring)")
    arguments = parser.parse_args()

    base = PROJECT_ROOT / "scratch_data" / "music_v9"
    directory = base / arguments.version
    songs: list[dict] = []
    for tier in TIERS:
        path = directory / f"{tier}.json"
        if not path.is_file():
            if arguments.partial:
                continue
            print(f"Missing tier file: {path}", file=sys.stderr)
            return 1
        songs.extend(json.loads(path.read_text(encoding="utf-8")))

    problems = validate(songs)
    if arguments.partial:
        problems = [p for p in problems if "expected 64 songs" not in p]
    if problems:
        print(f"VALIDATION: {len(problems)} problem(s) across {len(songs)} songs")
        for problem in problems:
            print(f"- {problem}")
        if not arguments.report_only:
            return 1
    else:
        print(f"Validation clean across {len(songs)} songs.")
    if arguments.report_only:
        return 0

    (base / f"{arguments.version}.json").write_text(
        json.dumps(songs, indent=2, ensure_ascii=False) + "\n", encoding="utf-8"
    )
    (base / f"{arguments.version}.yaml").write_text(
        emit_yaml(songs) + "\n", encoding="utf-8"
    )
    print(f"Wrote {base / (arguments.version + '.json')}")
    print(f"Wrote {base / (arguments.version + '.yaml')}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
