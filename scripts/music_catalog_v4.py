"""Load and validate the authored v4 five-tier music catalog (500 songs)."""

from __future__ import annotations

import json
import re
from dataclasses import dataclass
from pathlib import Path
from typing import Any

PROJECT_ROOT = Path(__file__).resolve().parent.parent
CATALOG_V4_PATH = PROJECT_ROOT / "scratch_data" / "music_catalog_v4.json"

SONGS_PER_TIER = 100
TOTAL_SONGS = 500


@dataclass(frozen=True)
class TierProfileV4:
    """Describe one alarm-music intensity tier."""

    identifier: str
    display_name: str
    bpm_low: int
    bpm_high: int
    energy_direction: str


TIER_PROFILES_V4 = (
    TierProfileV4(
        "soothing",
        "Soothing",
        58,
        82,
        "tender, spacious, reassuring, gentle enough for the very first wake cue",
    ),
    TierProfileV4(
        "relaxing",
        "Relaxing",
        78,
        104,
        "easygoing, warm, lightly propulsive, pleasant without demanding attention",
    ),
    TierProfileV4(
        "motivating",
        "Motivating",
        100,
        128,
        "confident, forward-moving, optimistic, built around a memorable lift",
    ),
    TierProfileV4(
        "energizing",
        "Energizing",
        126,
        162,
        "immediate, loud, athletic, celebratory, impossible to mistake for background music",
    ),
    TierProfileV4(
        "abrasive",
        "Abrasive",
        155,
        220,
        "hostile, alarm-like, distorted, relentless, engineered to defeat repeated snoozing",
    ),
)

TIER_BY_ID = {tier.identifier: tier for tier in TIER_PROFILES_V4}

# Mirror of the app's SoundVulgarity word weights (SoundLibrary.swift).
VULGARITY_WEIGHTS = {
    "ass": 2,
    "asshole": 4,
    "bastard": 2,
    "bitch": 3,
    "cunt": 5,
    "damn": 1,
    "dick": 4,
    "fuck": 4,
    "fucked": 4,
    "fucker": 4,
    "fucking": 4,
    "hell": 1,
    "pussy": 4,
    "shit": 3,
    "slut": 4,
    "whore": 4,
}

REQUIRED_TRACK_KEYS = {
    "number",
    "id",
    "intensityTier",
    "intensityName",
    "displayName",
    "filename",
    "artistName",
    "vocalistGender",
    "vocalistStyle",
    "language",
    "region",
    "genreName",
    "genreDescription",
    "bpm",
    "energyDirection",
    "comicPremise",
    "performedLyrics",
    "translation",
    "defaultSelected",
}


def vulgarity_score(track: dict[str, Any]) -> int:
    """Score a track's text exactly like the app: split on every non-letter."""
    text = [track["displayName"], track["artistName"], *track["performedLyrics"]]
    score = 0
    for chunk in text:
        for word in re.split(r"[^a-z]+", chunk.lower()):
            score += VULGARITY_WEIGHTS.get(word, 0)
    return score


def validate_catalog_v4(catalog: list[dict[str, Any]]) -> list[str]:
    """Return a list of human-readable validation problems (empty when valid)."""
    problems: list[str] = []
    if len(catalog) != TOTAL_SONGS:
        problems.append(f"Expected {TOTAL_SONGS} tracks, found {len(catalog)}")

    for key in ("id", "filename"):
        values = [str(track.get(key)) for track in catalog]
        if len(values) != len(set(values)):
            problems.append(f"Duplicate {key} values present")

    for unique_key in ("displayName", "artistName"):
        seen: dict[str, str] = {}
        for track in catalog:
            folded = str(track.get(unique_key, "")).strip().lower()
            if folded in seen:
                problems.append(
                    f"Duplicate {unique_key} '{track.get(unique_key)}' "
                    f"({seen[folded]} vs {track.get('id')})"
                )
            else:
                seen[folded] = str(track.get("id"))

    for tier in TIER_PROFILES_V4:
        tier_tracks = [
            track for track in catalog if track.get("intensityTier") == tier.identifier
        ]
        if len(tier_tracks) != SONGS_PER_TIER:
            problems.append(
                f"Expected {SONGS_PER_TIER} {tier.identifier} tracks, "
                f"found {len(tier_tracks)}"
            )
        genders = [track.get("vocalistGender") for track in tier_tracks]
        female = genders.count("female")
        male = genders.count("male")
        if female != SONGS_PER_TIER // 2 or male != SONGS_PER_TIER // 2:
            problems.append(
                f"{tier.identifier}: vocalist split is {female}F/{male}M, expected 50/50"
            )

    for track in catalog:
        label = f"{track.get('id', '?')} '{track.get('displayName', '?')}'"
        missing = REQUIRED_TRACK_KEYS - set(track)
        if missing:
            problems.append(f"{label}: missing keys {sorted(missing)}")
            continue
        tier = TIER_BY_ID.get(track["intensityTier"])
        if tier is None:
            problems.append(f"{label}: unknown tier {track['intensityTier']}")
            continue
        if track["vocalistGender"] not in ("female", "male"):
            problems.append(f"{label}: bad vocalistGender {track['vocalistGender']}")
        if not isinstance(track["bpm"], int) or not (
            tier.bpm_low <= track["bpm"] <= tier.bpm_high
        ):
            problems.append(
                f"{label}: bpm {track['bpm']} outside {tier.bpm_low}-{tier.bpm_high}"
            )
        lyrics = track["performedLyrics"]
        if not isinstance(lyrics, list) or len(lyrics) != 4:
            problems.append(f"{label}: expected exactly 4 lyric lines")
        else:
            for index, line in enumerate(lyrics):
                if not isinstance(line, str) or not line.strip():
                    problems.append(f"{label}: lyric line {index + 1} is empty")
                elif len(line) > 80:
                    problems.append(f"{label}: lyric line {index + 1} is too long")
        for text_key in (
            "displayName",
            "artistName",
            "vocalistStyle",
            "language",
            "region",
            "genreName",
            "genreDescription",
            "energyDirection",
            "comicPremise",
        ):
            if not str(track.get(text_key, "")).strip():
                problems.append(f"{label}: empty {text_key}")
        score = vulgarity_score(track)
        limit = 2 if track["intensityTier"] in ("energizing", "abrasive") else 0
        if score > limit:
            problems.append(
                f"{label}: vulgarity score {score} exceeds tier limit {limit}"
            )
    return problems


def load_catalog_v4(path: Path = CATALOG_V4_PATH) -> tuple[dict[str, Any], ...]:
    """Load the canonical catalog and fail on any validation problem."""
    catalog = json.loads(path.read_text(encoding="utf-8"))
    problems = validate_catalog_v4(catalog)
    if problems:
        detail = "\n".join(f"- {problem}" for problem in problems[:40])
        raise RuntimeError(
            f"Catalog {path} failed validation with {len(problems)} problem(s):\n{detail}"
        )
    return tuple(catalog)
