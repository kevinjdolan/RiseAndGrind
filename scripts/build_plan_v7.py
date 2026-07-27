#!/usr/bin/env python3
"""Merge, validate, and render the v7 song plan (10 songs per tier).

Reads scratch_data/music_v7/plan_vN/{tier}.json, runs the mechanical checks
from the compose-looping-alarm-songs skill (bar math, uniqueness, opening
words, motif budgets, vulgarity policy, timestamp sanity), and writes
plan_vN.json plus a reviewer-facing plan_vN.yaml.

Identical conventions to build_plan_v6.py, retargeted at scratch_data/music_v7.
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
from loop_bar_math import TARGET_SECONDS, TOLERANCE, fit_error  # noqa: E402
from music_catalog_v4 import VULGARITY_WEIGHTS  # noqa: E402

TIERS = ["soothing", "relaxing", "motivating", "energizing", "abrasive"]
REQUIRED_KEYS = {
    "id", "title", "artist", "genre", "vocalist", "bpm", "meter", "bars",
    "key", "instrumentation", "rhythm", "structure", "loopSeam", "lyrics",
    "premise",
}
MOTIF_BUDGETS = {
    "coffee": r"\bcoffee|espresso|latte\b",
    "inbox/email": r"\binbox|email|unread\b",
    "meetings": r"\bmeeting|standup\b",
    "calendar": r"\bcalendar\b",
    "snooze": r"\bsnooze\b",
    "sunrise-personification": r"\bsun\b.*\b(crew|creditor|collector|showing|arrived)\b",
}
VULGARITY_LIMITS = {"soothing": 0, "relaxing": 0, "motivating": 1, "energizing": 3, "abrasive": 16}
BANNED = {"bitch", "cunt", "slut", "whore", "pussy", "dick", "asshole"}


def vulgarity(song: dict) -> int:
    text = " ".join([song["title"], *song["lyrics"]]).lower()
    return sum(VULGARITY_WEIGHTS.get(w, 0) for w in re.split(r"[^a-z]+", text))


def validate(songs: list[dict]) -> list[str]:
    problems: list[str] = []
    for unique_key in ("id", "title", "artist"):
        counts = Counter(str(s[unique_key]).lower() for s in songs)
        for value, count in counts.items():
            if count > 1:
                problems.append(f"duplicate {unique_key}: {value}")
    for tier in TIERS:
        tier_songs = [s for s in songs if s["id"].startswith(tier)]
        if len(tier_songs) != 10:
            problems.append(f"{tier}: expected 10 songs, found {len(tier_songs)}")
        openers = Counter(s["lyrics"][0].split()[0].lower().strip(",:;") for s in tier_songs)
        for word, count in openers.items():
            if count > 1:
                problems.append(f"{tier}: opening word '{word}' used {count}x")
        for motif, pattern in MOTIF_BUDGETS.items():
            hits = [
                s["id"] for s in tier_songs
                if re.search(pattern, " ".join(s["lyrics"] + [s["premise"]]).lower())
            ]
            if len(hits) > 1:
                problems.append(f"{tier}: motif '{motif}' exceeds budget: {hits}")
        genders = Counter(s["vocalist"].split(";")[0].strip() for s in tier_songs)
        if genders.get("female") != 5 or genders.get("male") != 5:
            problems.append(f"{tier}: vocalist split {dict(genders)}, expected 5 female / 5 male")
    for s in songs:
        label = s.get("id", "?")
        missing = REQUIRED_KEYS - set(s)
        if missing:
            problems.append(f"{label}: missing keys {sorted(missing)}")
            continue
        error = fit_error(float(s["bpm"]), s["meter"], int(s["bars"]))
        if abs(error) > TOLERANCE:
            problems.append(f"{label}: bar math off by {error:+.2%}")
        if not (3 <= len(s["lyrics"]) <= 5):
            problems.append(f"{label}: {len(s['lyrics'])} lyric lines, expected 3-5")
        for line in s["lyrics"]:
            words = len(line.split())
            if not (3 <= words <= 10):
                problems.append(f"{label}: lyric line '{line}' has {words} words")
        text = " ".join(s["lyrics"] + [s["title"]]).lower()
        for banned in BANNED:
            if re.search(rf"\b{banned}\b", text):
                problems.append(f"{label}: banned word '{banned}'")
        tier = s["id"].split("_")[0]
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
        if times and times[-1] < TARGET_SECONDS - 0.1:
            problems.append(f"{label}: structure never reaches the loop wrap (~29.0)")
        if not any("= 0.0" in m or "=0.0" in m for m in s["structure"]):
            problems.append(f"{label}: no explicit wrap moment (29.0 = 0.0) in structure")
        if len(s["structure"]) < 6:
            problems.append(f"{label}: structure has under 6 moments")
    explicit = [
        s["id"] for s in songs
        if re.search(r"\b(wake up|get up|feet on|on the floor|stand up)\b", " ".join(s["lyrics"]).lower())
    ]
    if len(explicit) > 6:
        problems.append(f"explicit wake commands in {len(explicit)} songs: {explicit}")
    return problems


def yaml_quote(value: str) -> str:
    escaped = value.replace("\\", "\\\\").replace('"', '\\"')
    return f'"{escaped}"'


def emit_yaml(songs: list[dict]) -> str:
    lines = [
        "# Rise & Grind music plan v7 — 50 loop-first songs (10 per tier).",
        "# Composed under .claude/skills/compose-looping-alarm-songs.",
        "",
    ]
    for tier in TIERS:
        lines.append(f"{tier}:")
        for s in (x for x in songs if x["id"].startswith(tier)):
            lines.append(f"  - id: {s['id']}")
            for key in ("title", "artist", "genre", "vocalist"):
                lines.append(f"    {key}: {yaml_quote(s[key])}")
            lines.append(f"    bpm: {s['bpm']}")
            lines.append(f"    meter: {yaml_quote(s['meter'])}")
            lines.append(f"    bars: {s['bars']}")
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
    arguments = parser.parse_args()
    base = PROJECT_ROOT / "scratch_data" / "music_v7"
    directory = base / arguments.version
    songs: list[dict] = []
    for tier in TIERS:
        songs.extend(json.loads((directory / f"{tier}.json").read_text(encoding="utf-8")))
    problems = validate(songs)
    if problems:
        print(f"VALIDATION: {len(problems)} problem(s)")
        for problem in problems:
            print(f"- {problem}")
        if not arguments.report_only:
            return 1
    else:
        print("Validation clean.")
    if arguments.report_only:
        return 0
    (base / f"{arguments.version}.json").write_text(
        json.dumps(songs, indent=2, ensure_ascii=False) + "\n", encoding="utf-8"
    )
    (base / f"{arguments.version}.yaml").write_text(emit_yaml(songs) + "\n", encoding="utf-8")
    print(f"Wrote {base / (arguments.version + '.json')}")
    print(f"Wrote {base / (arguments.version + '.yaml')}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
