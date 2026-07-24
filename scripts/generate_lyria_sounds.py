#!/usr/bin/env python3
"""Generate and validate the 100-track looping Rise & Grind alarm library."""

from __future__ import annotations

import argparse
from array import array
import base64
import concurrent.futures
import hashlib
import json
import math
import os
from pathlib import Path
import random
import re
import shutil
import subprocess
import sys
import tempfile
import threading
import time
from typing import Any
import urllib.error
import urllib.request

from lyria_catalog import EXPANSION_TRACKS


MODEL = "lyria-3-clip-preview"
ENDPOINT = "https://generativelanguage.googleapis.com/v1beta/interactions"
TRACK_SECONDS = 29.0
SOURCE_MINIMUM_SECONDS = 29.5
SAMPLE_RATE = 44_100
SAMPLE_COUNT = round(TRACK_SECONDS * SAMPLE_RATE)
LOOP_CROSSFADE_SECONDS = 0.5
MAXIMUM_PEAK_DBFS = -0.5
MAXIMUM_TRUE_PEAK_DBFS = -0.1
MAXIMUM_FILE_BYTES = 800_000

PROJECT_ROOT = Path(__file__).resolve().parent.parent
AUDIO_DIRECTORY = PROJECT_ROOT / "RiseAndGrind" / "Resources" / "Sounds"
LEGACY_MASTER_DIRECTORY = PROJECT_ROOT / "RiseAndGrind" / "Resources" / "SoundMasters"
MANIFEST_PATH = AUDIO_DIRECTORY / "manifest.json"
LYRICS_SOURCE_PATH = (
    PROJECT_ROOT / "GeneratedSamples" / "RiseAndGrind_24_One_Minute_Songs.md"
)
CATALOG_PATH = PROJECT_ROOT / "GeneratedSamples" / "RiseAndGrind_100_Alarm_Catalog.json"
LYRIA_RESPONSE_DIRECTORY = PROJECT_ROOT / "GeneratedSamples" / "LyriaResponses"
VERIFICATION_REPORT_PATH = LYRIA_RESPONSE_DIRECTORY / "verification.json"

PRINT_LOCK = threading.Lock()


LEGACY_SOUND_IDENTITIES: tuple[tuple[str, str], ...] = (
    ("air_raid_arsenal", "AirRaidArsenal"),
    ("industrial_panic", "IndustrialPanic"),
    ("brass_knuckle_march", "BrassKnuckleMarch"),
    ("emergency_rave", "EmergencyRave"),
    ("jackhammer_jubilee", "JackhammerJubilee"),
    ("siren_storm", "SirenStorm"),
    ("circuit_breaker", "CircuitBreaker"),
    ("factory_floor_frenzy", "FactoryFloorFrenzy"),
    ("alarm_bell_assault", "AlarmBellAssault"),
    ("neon_fire_drill", "NeonFireDrill"),
    ("percussion_overload", "PercussionOverload"),
    ("hornet_nest", "HornetNest"),
    ("boiler_room_barrage", "BoilerRoomBarrage"),
    ("buzzsaw_breakbeat", "BuzzsawBreakbeat"),
    ("cymbal_crash_course", "CymbalCrashCourse"),
    ("diesel_drumline", "DieselDrumline"),
    ("electric_shock", "ElectricShock"),
    ("firehouse_fanfare", "FirehouseFanfare"),
    ("metallic_mayhem", "MetallicMayhem"),
    ("pressure_valve", "PressureValve"),
    ("subway_screech", "SubwayScreech"),
    ("warning_signal", "WarningSignal"),
    ("wake_up_warpath", "WakeUpWarpath"),
    ("sonic_defibrillator", "SonicDefibrillator"),
)

LEGACY_GENRE_NAMES: tuple[str, ...] = (
    "Thrash Metal",
    "Hardcore Punk",
    "Industrial Metal",
    "Metalcore",
    "Deathcore",
    "Crossover Thrash",
    "Power Metal",
    "Nu Metal",
    "Festival EDM",
    "Drum and Bass",
    "Hardstyle",
    "Gabber",
    "Breakcore",
    "Electroclash",
    "Warehouse Techno",
    "Industrial Dance",
    "Trap",
    "Boom Bap",
    "Grime",
    "Rage Rap",
    "Phonk",
    "Jersey Club",
    "Rap Punk",
    "Funk Metal",
)

LEGACY_VOCAL_DIRECTIONS: tuple[str, ...] = (
    "A ferocious female lead uses intelligible fry screams backed by gang shouts.",
    "A snarling hardcore lead shouts each line with a rowdy mixed-gender gang chorus.",
    "A clipped industrial vocalist barks orders through restrained machine distortion.",
    "Alternate vicious screamed lines with one soaring clean-sung response.",
    "Use cavernous low growls that remain clearly enunciated.",
    "Use a hoarse crossover-thrash shout with a circle-pit gang response.",
    "Use a heroic high tenor with stacked choir answers.",
    "Use a furious percussive rap-metal lead with a shouted hook.",
    "Use a commanding festival vocalist with urgent builds and crowd shouts.",
    "Use a rapid, razor-clear emcee delivery with terse spoken commands.",
    "Use an anthemic hardstyle vocalist and enormous crowd shouts.",
    "Use abrasive gabber shouts while keeping every word intelligible.",
    "Chop a hyperactive lead into glitch fragments without changing word order.",
    "Use a sneering female electroclash lead: cool, glamorous, and sharply sung.",
    "Use a hypnotic spoken chant with restrained vocoder doubles.",
    "Use a mechanized industrial bark with synchronized worker-gang answers.",
    "Use a confident volcanic rapper with a forceful melodic hook.",
    "Use a sharp-tongued emcee with impeccable diction and no sung melody.",
    "Use a breathless grime emcee with clipped phrasing and crew answers.",
    "Use an explosive rage-rap lead with blown-out crowd chants.",
    "Use a grave-low menacing vocal that remains fully intelligible.",
    "Use rhythmic call-and-response with short chopped repeats.",
    "Use a fierce punk rapper with angry roommate-style gang vocals.",
    "Use agile rapid-fire funk-metal rap with a full-band hook.",
)


class GenerationError(RuntimeError):
    """Report an audio-generation or media-validation failure."""


def log(message: str) -> None:
    """Print one complete progress line without interleaving worker output."""
    with PRINT_LOCK:
        print(message, flush=True)


def run(
    command: list[str], *, capture_output: bool = True
) -> subprocess.CompletedProcess[str]:
    """Run a local media command and raise a readable error on failure."""
    result = subprocess.run(
        command,
        check=False,
        capture_output=capture_output,
        text=True,
    )
    if result.returncode != 0:
        detail = result.stderr.strip() or result.stdout.strip() or "unknown command failure"
        raise GenerationError(f"{Path(command[0]).name} failed: {detail[-1_500:]}")
    return result


def parse_lyric_sections(lyrics: str) -> list[tuple[str, str]]:
    """Parse labeled sections from the original 24-song lyric book."""
    matches = list(
        re.finditer(
            r"^\*\*\[(?P<label>[^\]]+)\]\*\*  \n(?P<body>.*?)(?=\n\n\*\*\[|\Z)",
            lyrics,
            re.MULTILINE | re.DOTALL,
        )
    )
    if not matches:
        raise GenerationError("Lyric sheet contains no labeled sections")
    return [
        (match.group("label").strip(), match.group("body").strip())
        for match in matches
    ]


def compact_performance_lines(lyrics: str, maximum_words: int = 52) -> tuple[str, ...]:
    """Select an ordered compact excerpt that fits a 29-second performance."""
    candidates = [
        line.strip()
        for _, body in parse_lyric_sections(lyrics)
        for line in body.splitlines()
        if line.strip()
    ]
    selected: list[str] = []
    word_count = 0
    for line in candidates:
        if len(selected) == 8:
            break
        line_words = len(re.findall(r"[\w’']+", line))
        if len(selected) >= 3 and word_count + line_words > maximum_words:
            break
        selected.append(line)
        word_count += line_words
    if len(selected) < 3:
        raise GenerationError("Compact lyric excerpt contained fewer than three lines")
    return tuple(selected)


def expansion_vocal_direction(genre_name: str, female_slut_pride: bool) -> str:
    """Return a genre-aware vocal instruction for an expansion track."""
    if female_slut_pride:
        return (
            "Use an unmistakably adult female lead with dominant, joyful slut-pride energy. "
            "Make consent, agency, and every profane lyric exceptionally clear."
        )
    if any(
        word in genre_name
        for word in ("Rap", "Trap", "Grime", "Drill", "Phonk", "Hip Hop", "Boom Bap")
    ):
        return "Use an aggressive, rhythmically precise emcee with crisp diction and terse gang answers."
    if any(
        word in genre_name
        for word in ("Techno", "EDM", "Trance", "House", "Gabber", "Hardstyle", "EBM")
    ):
        return "Use a forceful club vocalist with short spoken commands and an enormous crowd response."
    if any(
        word in genre_name
        for word in ("Jazz", "Band", "Brass", "Swing", "Bebop", "Drumline")
    ):
        return "Use a theatrical bandleader vocal with fast, intelligible phrasing and ensemble shouts."
    return "Use an abrasive, fully intelligible lead vocal with tightly synchronized gang responses."


def load_sound_catalog() -> tuple[dict[str, Any], ...]:
    """Load the preserved 24-song book and append the authored 76-song expansion."""
    try:
        source = LYRICS_SOURCE_PATH.read_text(encoding="utf-8")
    except OSError as error:
        raise RuntimeError(f"Unable to read lyric book: {LYRICS_SOURCE_PATH}") from error
    pattern = re.compile(
        r'^## (?P<number>\d+)\. [“"](?P<title>.+?)[”"]\n\n'
        r'\*\*Band:\*\* (?P<band>.+?)  \n'
        r'\*\*Genre:\*\* (?P<genre>.+?)\n\n'
        r'### Lyrics\n\n'
        r'(?P<lyrics>.*?)(?=\n## \d+\. |\Z)',
        re.MULTILINE | re.DOTALL,
    )
    songs = list(pattern.finditer(source))
    if len(songs) != 24:
        raise RuntimeError(f"Expected 24 preserved songs, found {len(songs)}")

    catalog: list[dict[str, Any]] = []
    for index, values in enumerate(
        zip(
            songs,
            LEGACY_SOUND_IDENTITIES,
            LEGACY_GENRE_NAMES,
            LEGACY_VOCAL_DIRECTIONS,
        ),
        start=1,
    ):
        match, identity, genre_name, vocal_direction = values
        if int(match.group("number")) != index:
            raise RuntimeError(f"Preserved song {index} is misnumbered")
        identifier, filename = identity
        lyrics = match.group("lyrics").strip()
        catalog.append(
            {
                "number": index,
                "id": identifier,
                "displayName": match.group("title").strip(),
                "filename": filename,
                "band": match.group("band").strip(),
                "genreName": genre_name,
                "genreDescription": match.group("genre").strip(),
                "vocalDirection": vocal_direction,
                "lyrics": lyrics,
                "performedLyrics": compact_performance_lines(lyrics),
                "femaleSlutPride": False,
                "defaultSelected": True,
            }
        )

    for index, track in enumerate(EXPANSION_TRACKS, start=25):
        catalog.append(
            {
                "number": index,
                "id": f"rise_track_{index:03d}",
                "displayName": track.title,
                "filename": f"RiseTrack{index:03d}",
                "band": track.band,
                "genreName": track.genre_name,
                "genreDescription": track.genre_description,
                "vocalDirection": expansion_vocal_direction(
                    track.genre_name, track.female_slut_pride
                ),
                "lyrics": "\n".join(track.lyrics),
                "performedLyrics": track.lyrics,
                "femaleSlutPride": track.female_slut_pride,
                "defaultSelected": True,
            }
        )

    validate_catalog_metadata(catalog)
    return tuple(catalog)


def validate_catalog_metadata(catalog: list[dict[str, Any]]) -> None:
    """Require complete, unique metadata and the requested adult anthem coverage."""
    if len(catalog) != 100:
        raise RuntimeError(f"Expected 100 catalog tracks, found {len(catalog)}")
    for key in ("id", "displayName", "filename", "band"):
        values = [str(sound[key]) for sound in catalog]
        if len(set(values)) != len(values):
            raise RuntimeError(f"Catalog contains duplicate {key} values")
    for sound in catalog:
        word_count = len(str(sound["genreName"]).split())
        if not 1 <= word_count <= 3:
            raise RuntimeError(
                f"Genre label must contain 1–3 words: {sound['genreName']}"
            )
        if not 3 <= len(sound["performedLyrics"]) <= 8:
            raise RuntimeError(
                f"Performed lyrics must contain 3–8 lines: {sound['displayName']}"
            )
    pride_count = sum(bool(sound["femaleSlutPride"]) for sound in catalog)
    if pride_count < 12:
        raise RuntimeError(f"Expected at least 12 female slut-pride tracks, found {pride_count}")


SOUNDS = load_sound_catalog()


def probe_audio(path: Path) -> dict[str, Any]:
    """Return the first audio stream and container duration from ffprobe."""
    result = run(
        [
            "ffprobe",
            "-v",
            "error",
            "-show_entries",
            "format=duration,size:stream=codec_name,sample_rate,channels",
            "-select_streams",
            "a:0",
            "-of",
            "json",
            str(path),
        ]
    )
    payload = json.loads(result.stdout)
    streams = payload.get("streams") or []
    if not streams:
        raise GenerationError(f"No audio stream found in {path}")
    stream = streams[0]
    stream["duration"] = float(payload["format"]["duration"])
    stream["size"] = int(payload["format"]["size"])
    return stream


def timed_lyrics(lines: tuple[str, ...]) -> str:
    """Assign each compact lyric line a concrete performance window."""
    vocal_start = 0.8
    vocal_end = 26.0
    slot = (vocal_end - vocal_start) / len(lines)
    return "\n".join(
        f"[{vocal_start + index * slot:04.1f}s-"
        f"{vocal_start + (index + 1) * slot:04.1f}s] {line}"
        for index, line in enumerate(lines)
    )


def make_prompt(sound: dict[str, Any]) -> str:
    """Build a 30-second Lyria source prompt authored for a seamless 29-second loop."""
    pride_direction = (
        "This is an adult, consensual female slut-pride anthem. Celebrate sexual agency "
        "without coercion, degradation by another person, or ambiguity about consent."
        if sound["femaleSlutPride"]
        else ""
    )
    return "\n".join(
        part
        for part in (
            f'Create an original 30-second source clip titled "{sound["displayName"]}".',
            f"GENRE: {sound['genreDescription']}",
            f"VOCAL: {sound['vocalDirection']}",
            pride_direction,
            "Make it abrasive, high-energy, phone-speaker-forward, rhythmically precise, and "
            "instantly loud. Do not imitate any existing artist, song, melody, or recording.",
            "Author the arrangement as a continuous loop. From 0.0–0.8 seconds play a "
            "distinctive instrumental pickup with no voice. From 26.0–29.5 seconds return "
            "to exactly the same groove, harmony, instrumentation, and energy as that pickup. "
            "Do not cadence, fade, stop, add silence, or land a final hit.",
            "Perform every lyric below exactly once, verbatim, in order. Do not censor, "
            "paraphrase, repeat, omit, or add words. Keep every word intelligible.",
            "TIMESTAMPED LYRICS:",
            timed_lyrics(tuple(sound["performedLyrics"])),
            "From 29.5–30.0 seconds keep the same opening groove running without vocals so "
            "post-production can overlap the boundary into a seamless 29-second cycle.",
        )
        if part
    )


def normalized_lyric_text(text: str) -> str:
    """Normalize punctuation and casing while retaining lyric word order."""
    return " ".join(re.findall(r"[a-z0-9]+", text.casefold()))


def validate_response_text(text: str, lines: tuple[str, ...]) -> dict[str, int]:
    """Require timed Lyria evidence containing every performed lyric line in order."""
    if not text.strip():
        raise GenerationError("Lyria response contained audio but no lyric text")
    timestamp_count = len(
        re.findall(r"\[\s*\d+(?:\.\d+)?\s*:(?:\s*\d+(?:\.\d+)?)?\s*\]", text)
    )
    if timestamp_count == 0:
        raise GenerationError("Lyria lyric report did not contain timed vocal lines")
    normalized_response = normalized_lyric_text(text)
    cursor = 0
    missing_lines: list[str] = []
    for line in lines:
        normalized_line = normalized_lyric_text(line)
        match_index = normalized_response.find(normalized_line, cursor)
        if match_index < 0:
            missing_lines.append(line)
        else:
            cursor = match_index + len(normalized_line)
    if missing_lines:
        preview = " | ".join(missing_lines[:3])
        raise GenerationError(
            f"Lyria lyric report omitted {len(missing_lines)}/{len(lines)} "
            f"performed line(s): {preview}"
        )
    return {
        "timestampCount": timestamp_count,
        "characterCount": len(text),
        "performedLineCount": len(lines),
        "matchedLineCount": len(lines),
    }


def extract_result(
    payload: dict[str, Any], lines: tuple[str, ...]
) -> tuple[bytes, dict[str, Any]]:
    """Extract generated audio and non-secret API-result evidence."""
    audio: bytes | None = None
    text_blocks: list[str] = []
    for step in payload.get("steps") or []:
        if step.get("type") != "model_output":
            continue
        for content in step.get("content") or []:
            if content.get("type") == "audio" and content.get("data"):
                try:
                    audio = base64.b64decode(content["data"])
                except (ValueError, TypeError) as error:
                    raise GenerationError("Lyria returned invalid base64 audio") from error
            elif content.get("type") == "text" and content.get("text"):
                text_blocks.append(str(content["text"]).strip())
    if payload.get("error"):
        raise GenerationError(f"Lyria API error: {str(payload['error'])[:500]}")
    if audio is None:
        raise GenerationError("Lyria response contained no audio block")
    text = "\n\n".join(block for block in text_blocks if block).strip()
    validate_response_text(text, lines)
    return audio, {
        "model": MODEL,
        "endpoint": ENDPOINT,
        "interactionID": payload.get("id"),
        "stepCount": len(payload.get("steps") or []),
        "responseKeys": sorted(payload.keys()),
        "modelText": text,
        "audioByteCount": len(audio),
    }


def request_audio(
    prompt: str,
    lines: tuple[str, ...],
    api_key: str,
    max_attempts: int,
    label: str,
) -> tuple[bytes, dict[str, Any]]:
    """Request Lyria audio and lyrics with bounded exponential retries."""
    body = json.dumps({"model": MODEL, "input": prompt}).encode("utf-8")
    for attempt in range(1, max_attempts + 1):
        request = urllib.request.Request(
            ENDPOINT,
            data=body,
            method="POST",
            headers={
                "Content-Type": "application/json",
                "x-goog-api-key": api_key,
                "User-Agent": "RiseAndGrind-SoundGenerator/2.0",
            },
        )
        try:
            with urllib.request.urlopen(request, timeout=900) as response:
                payload = json.loads(response.read())
            return extract_result(payload, lines)
        except urllib.error.HTTPError as error:
            response_text = error.read().decode("utf-8", errors="replace")[:500]
            retryable = error.code in {408, 409, 429, 500, 502, 503, 504}
            reason = f"HTTP {error.code}: {response_text}"
        except (urllib.error.URLError, TimeoutError, json.JSONDecodeError) as error:
            retryable = True
            reason = f"{type(error).__name__}: {error}"
        except GenerationError as error:
            retryable = True
            reason = str(error)

        if not retryable or attempt == max_attempts:
            raise GenerationError(
                f"{label} failed after {attempt} attempt(s): {reason}"
            )
        delay = min(60.0, (2 ** (attempt - 1)) * 3.0 + random.uniform(0.0, 2.0))
        log(
            f"RETRY {label}: attempt {attempt}/{max_attempts} failed; "
            f"waiting {delay:.1f}s ({reason})"
        )
        time.sleep(delay)
    raise AssertionError("retry loop exited unexpectedly")


def standardize_loop(source: Path, destination: Path, work_directory: Path) -> None:
    """Create an exact, loud, phone-focused, seamless IMA4/CAF loop."""
    source_metadata = probe_audio(source)
    if source_metadata["duration"] < SOURCE_MINIMUM_SECONDS:
        raise GenerationError(
            f"Lyria source was only {source_metadata['duration']:.3f} seconds"
        )
    if int(source_metadata.get("channels", 0)) != 2:
        raise GenerationError("Lyria source was not stereo")
    pcm_path = work_directory / "loop-pcm.wav"
    source_sample_count = round(30.0 * SAMPLE_RATE)
    crossfade_sample_count = round(LOOP_CROSSFADE_SECONDS * SAMPLE_RATE)
    main_end_sample = SAMPLE_COUNT
    bridge_end_sample = SAMPLE_COUNT + crossfade_sample_count
    filter_graph = (
        f"[0:a]aresample={SAMPLE_RATE},pan=mono|c0=0.707*FL+0.707*FR,"
        "highpass=f=85,lowpass=f=11500,"
        "equalizer=f=2800:t=q:w=1:g=2.2,"
        "acompressor=threshold=0.08:ratio=6:attack=3:release=60:makeup=5,"
        f"aresample={SAMPLE_RATE},alimiter=limit=0.70:attack=5:release=50:"
        f"level=false:latency=true,apad=whole_len={source_sample_count},"
        f"atrim=end_sample={source_sample_count},asetpts=N/SR/TB,"
        "asplit=3[main_source][tail_source][head_source];"
        f"[main_source]atrim=start_sample={crossfade_sample_count}:"
        f"end_sample={main_end_sample},asetpts=N/SR/TB[main];"
        f"[tail_source]atrim=start_sample={main_end_sample}:"
        f"end_sample={bridge_end_sample},asetpts=N/SR/TB[tail];"
        f"[head_source]atrim=start_sample=0:end_sample={crossfade_sample_count},"
        "asetpts=N/SR/TB[head];"
        f"[tail][head]acrossfade=d={LOOP_CROSSFADE_SECONDS}:c1=tri:c2=tri[bridge];"
        f"[main][bridge]concat=n=2:v=0:a=1,atrim=end_sample={SAMPLE_COUNT},"
        "afade=t=in:st=0:d=0.006,afade=t=out:st=28.994:d=0.006,"
        "asetpts=N/SR/TB[output]"
    )
    run(
        [
            "ffmpeg",
            "-hide_banner",
            "-loglevel",
            "error",
            "-y",
            "-i",
            str(source),
            "-filter_complex",
            filter_graph,
            "-map",
            "[output]",
            "-ar",
            str(SAMPLE_RATE),
            "-ac",
            "1",
            "-c:a",
            "pcm_s16le",
            str(pcm_path),
        ]
    )
    run(
        [
            "afconvert",
            str(pcm_path),
            str(destination),
            "-d",
            "ima4",
            "-f",
            "caff",
        ]
    )


def decode_caf(path: Path, destination: Path) -> None:
    """Decode one IMA4/CAF file to PCM for independent signal validation."""
    run(
        [
            "afconvert",
            str(path),
            str(destination),
            "-d",
            "LEI16",
            "-f",
            "WAVE",
        ]
    )


def decoded_samples(path: Path) -> array[int]:
    """Decode a PCM file to signed 16-bit samples."""
    result = subprocess.run(
        [
            "ffmpeg",
            "-hide_banner",
            "-loglevel",
            "error",
            "-i",
            str(path),
            "-map",
            "0:a:0",
            "-ar",
            str(SAMPLE_RATE),
            "-ac",
            "1",
            "-c:a",
            "pcm_s16le",
            "-f",
            "s16le",
            "pipe:1",
        ],
        check=False,
        capture_output=True,
    )
    if result.returncode != 0:
        detail = result.stderr.decode("utf-8", errors="replace")[-1_000:]
        raise GenerationError(f"Unable to decode PCM samples: {detail}")
    samples = array("h")
    samples.frombytes(result.stdout)
    if sys.byteorder != "little":
        samples.byteswap()
    return samples


def measure_loudness(path: Path) -> dict[str, float]:
    """Measure integrated and true-peak loudness with FFmpeg's EBU R128 meter."""
    result = subprocess.run(
        [
            "ffmpeg",
            "-hide_banner",
            "-nostats",
            "-i",
            str(path),
            "-filter_complex",
            "ebur128=peak=true",
            "-f",
            "null",
            "-",
        ],
        check=False,
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        raise GenerationError(f"Unable to meter loudness: {result.stderr[-1_000:]}")
    integrated_values = re.findall(r"I:\s+(-?\d+(?:\.\d+)?) LUFS", result.stderr)
    peak_values = re.findall(r"Peak:\s+(-?\d+(?:\.\d+)?) dBFS", result.stderr)
    if not integrated_values or not peak_values:
        raise GenerationError("Unable to parse EBU R128 loudness summary")
    return {
        "integratedLoudnessLUFS": float(integrated_values[-1]),
        "truePeakDbFS": float(peak_values[-1]),
    }


def validate_audio(path: Path) -> dict[str, Any]:
    """Validate exact duration, format, loudness, file size, and loop boundary."""
    if not path.is_file() or path.stat().st_size == 0:
        raise GenerationError(f"Missing alarm loop: {path}")
    afinfo = run(["afinfo", str(path)]).stdout
    if "ima4" not in afinfo or "Channel layout: Mono" not in afinfo:
        raise GenerationError(f"Audio is not mono IMA4/CAF: {path}")
    duration_match = re.search(r"estimated duration:\s+([\d.]+) sec", afinfo)
    frame_match = re.search(r"audio\s+(\d+) valid frames", afinfo)
    sample_rate_match = re.search(r"1 ch,\s+(\d+) Hz", afinfo)
    if not duration_match or not frame_match or not sample_rate_match:
        raise GenerationError(f"Unable to parse afinfo metadata: {path}")
    duration = float(duration_match.group(1))
    frames = int(frame_match.group(1))
    sample_rate = int(sample_rate_match.group(1))
    if duration != TRACK_SECONDS or frames != SAMPLE_COUNT:
        raise GenerationError(
            f"Audio is not exactly {TRACK_SECONDS:.3f}s/{SAMPLE_COUNT} frames: {path} "
            f"({duration:.6f}s/{frames} frames)"
        )
    if sample_rate != SAMPLE_RATE:
        raise GenerationError(f"Audio sample rate is not {SAMPLE_RATE}: {path}")
    file_size = path.stat().st_size
    if file_size > MAXIMUM_FILE_BYTES:
        raise GenerationError(
            f"Audio exceeds {MAXIMUM_FILE_BYTES} bytes: {path} ({file_size})"
        )

    with tempfile.TemporaryDirectory(prefix="rise-loop-validation-") as temporary:
        decoded_path = Path(temporary) / "decoded.wav"
        decode_caf(path, decoded_path)
        decoded_metadata = probe_audio(decoded_path)
        samples = decoded_samples(decoded_path)
        loudness = measure_loudness(decoded_path)
    if len(samples) != SAMPLE_COUNT:
        raise GenerationError(f"Decoded sample count is not {SAMPLE_COUNT}: {path}")
    peak = max((abs(sample) for sample in samples), default=0) / 32_768.0
    peak_dbfs = 20.0 * math.log10(peak) if peak else float("-inf")
    if peak_dbfs > MAXIMUM_PEAK_DBFS:
        raise GenerationError(
            f"Decoded peak exceeds {MAXIMUM_PEAK_DBFS:.1f} dBFS: {path} "
            f"({peak_dbfs:.2f} dBFS)"
        )
    integrated = loudness["integratedLoudnessLUFS"]
    if not -14.0 <= integrated <= -7.0:
        raise GenerationError(f"Integrated loudness is out of range: {path} ({integrated})")
    if loudness["truePeakDbFS"] > MAXIMUM_TRUE_PEAK_DBFS:
        raise GenerationError(
            f"True peak exceeds {MAXIMUM_TRUE_PEAK_DBFS:.1f} dBFS: {path} "
            f"({loudness['truePeakDbFS']:.1f} dBFS)"
        )
    seam_delta = abs(samples[0] - samples[-1]) / 32_768.0
    seam_delta_dbfs = 20.0 * math.log10(seam_delta) if seam_delta else float("-inf")
    if seam_delta > 0.125:
        raise GenerationError(
            f"Loop boundary jump is too large: {path} ({seam_delta_dbfs:.2f} dBFS)"
        )
    return {
        "duration": duration,
        "sampleCount": frames,
        "sampleRate": sample_rate,
        "channels": 1,
        "codec": "ima4",
        "container": "caf",
        "fileBytes": file_size,
        "decodedCodec": decoded_metadata["codec_name"],
        "samplePeakDbFS": peak_dbfs,
        "integratedLoudnessLUFS": integrated,
        "truePeakDbFS": loudness["truePeakDbFS"],
        "loopSeamDeltaDbFS": seam_delta_dbfs,
        "sha256": hashlib.sha256(path.read_bytes()).hexdigest(),
    }


def audio_path_for(sound: dict[str, Any]) -> Path:
    """Return the installed CAF path for one catalog entry."""
    return AUDIO_DIRECTORY / f"{sound['filename']}.caf"


def response_path_for(sound: dict[str, Any]) -> Path:
    """Return the persisted non-secret Lyria-result record for one catalog entry."""
    return LYRIA_RESPONSE_DIRECTORY / f"{sound['id']}.json"


def validate_response_file(path: Path, lines: tuple[str, ...]) -> dict[str, Any]:
    """Validate one persisted model-result record and its lyric evidence."""
    if not path.is_file() or path.stat().st_size == 0:
        raise GenerationError(f"Missing Lyria result record: {path}")
    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        raise GenerationError(f"Unreadable Lyria result record: {path}") from error
    if payload.get("model") != MODEL or payload.get("endpoint") != ENDPOINT:
        raise GenerationError(f"Lyria model/API metadata mismatch: {path}")
    metadata = validate_response_text(str(payload.get("modelText", "")), lines)
    metadata.update(
        {
            "model": payload["model"],
            "endpoint": payload["endpoint"],
            "interactionID": payload.get("interactionID"),
            "stepCount": int(payload.get("stepCount", 0)),
            "apiAudioBytes": int(payload.get("audioByteCount", 0)),
            "sourceAudio": payload.get("sourceAudio") or {},
        }
    )
    if metadata["stepCount"] < 1 or metadata["apiAudioBytes"] < 1:
        raise GenerationError(f"Lyria result record lacks API evidence: {path}")
    return metadata


def outputs_are_valid(sound: dict[str, Any]) -> bool:
    """Return whether one installed loop and its API evidence pass validation."""
    try:
        validate_audio(audio_path_for(sound))
        validate_response_file(
            response_path_for(sound), tuple(sound["performedLyrics"])
        )
    except (GenerationError, KeyError, TypeError, ValueError):
        return False
    return True


def generate_sound(
    sound: dict[str, Any], api_key: str, max_attempts: int, force: bool
) -> dict[str, Any]:
    """Generate, validate, and atomically install one catalog entry."""
    label = str(sound["displayName"])
    destination = audio_path_for(sound)
    response_destination = response_path_for(sound)
    if not force and outputs_are_valid(sound):
        log(f"SKIP  {sound['number']:03d} {label}: existing output is valid")
        return {"id": sound["id"], "status": "skipped"}

    log(f"START {sound['number']:03d} {label}")
    with tempfile.TemporaryDirectory(prefix="rise-and-grind-lyria-") as temporary:
        temporary_directory = Path(temporary)
        raw_audio = temporary_directory / "lyria-response.mp3"
        pending_audio = temporary_directory / destination.name
        pending_response = temporary_directory / response_destination.name
        raw_metadata: dict[str, Any] | None = None
        response_record: dict[str, Any] | None = None
        for media_attempt in range(1, max_attempts + 1):
            audio, response_record = request_audio(
                make_prompt(sound),
                tuple(sound["performedLyrics"]),
                api_key,
                max_attempts,
                label,
            )
            raw_audio.write_bytes(audio)
            raw_metadata = probe_audio(raw_audio)
            if raw_metadata["duration"] >= SOURCE_MINIMUM_SECONDS:
                break
            if media_attempt == max_attempts:
                raise GenerationError(
                    f"Lyria returned a short source on {media_attempt} attempts; latest was "
                    f"{raw_metadata['duration']:.3f} seconds"
                )
            log(
                f"RETRY {label}: source attempt {media_attempt}/{max_attempts} was only "
                f"{raw_metadata['duration']:.3f} seconds"
            )
        if raw_metadata is None or response_record is None:
            raise AssertionError("media retry loop exited unexpectedly")
        response_record["sourceAudio"] = {
            "duration": raw_metadata["duration"],
            "codec": raw_metadata["codec_name"],
            "sampleRate": int(raw_metadata["sample_rate"]),
            "channels": int(raw_metadata["channels"]),
            "fileBytes": raw_metadata["size"],
        }
        standardize_loop(raw_audio, pending_audio, temporary_directory)
        pending_response.write_text(
            json.dumps(response_record, indent=2) + "\n", encoding="utf-8"
        )
        audio_metadata = validate_audio(pending_audio)
        response_metadata = validate_response_file(
            pending_response, tuple(sound["performedLyrics"])
        )
        pending_audio.replace(destination)
        pending_response.replace(response_destination)

    log(
        f"DONE  {sound['number']:03d} {label}: {audio_metadata['duration']:.3f}s "
        f"IMA4 {audio_metadata['fileBytes'] / 1024:.0f} KiB, "
        f"{audio_metadata['integratedLoudnessLUFS']:.1f} LUFS, "
        f"{response_metadata['timestampCount']} timed lyrics"
    )
    return {"id": sound["id"], "status": "generated"}


def manifest_track(sound: dict[str, Any]) -> dict[str, Any]:
    """Build the public manifest representation for one sound."""
    filename = f"{sound['filename']}.caf"
    return {
        "id": sound["id"],
        "displayName": sound["displayName"],
        "artistName": sound["band"],
        "genreName": sound["genreName"],
        "genreDescription": sound["genreDescription"],
        "lyrics": sound["lyrics"],
        "performedLyrics": list(sound["performedLyrics"]),
        "femaleSlutPride": sound["femaleSlutPride"],
        "alarmFilename": filename,
        "previewFilename": filename,
        "defaultSelected": True,
        "durationSeconds": TRACK_SECONDS,
        "loopAuthored": True,
        "model": MODEL,
    }


def catalog_record(sound: dict[str, Any]) -> dict[str, Any]:
    """Build the complete reproducible authored-catalog record."""
    return {
        "number": sound["number"],
        **manifest_track(sound),
        "vocalDirection": sound["vocalDirection"],
    }


def write_json_atomically(path: Path, payload: Any) -> None:
    """Write indented JSON through a same-directory atomic replacement."""
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")
    temporary.replace(path)


def write_catalog() -> None:
    """Write the complete authored 100-track generation catalog."""
    write_json_atomically(CATALOG_PATH, [catalog_record(sound) for sound in SOUNDS])


def write_manifest() -> None:
    """Write the runtime manifest with global format and generation metadata."""
    payload = {
        "schemaVersion": 2,
        "trackCount": len(SOUNDS),
        "model": MODEL,
        "generationAPI": ENDPOINT,
        "durationSeconds": TRACK_SECONDS,
        "loopingPreview": True,
        "audioFormat": {
            "container": "caf",
            "codec": "ima4",
            "sampleRate": SAMPLE_RATE,
            "channels": 1,
        },
        "tracks": [manifest_track(sound) for sound in SOUNDS],
    }
    write_json_atomically(MANIFEST_PATH, payload)


def verify_catalog(
    catalog: tuple[dict[str, Any], ...] | list[dict[str, Any]] = SOUNDS,
) -> list[dict[str, Any]]:
    """Validate catalog artifacts and return full media and API evidence."""
    report: list[dict[str, Any]] = []
    for sound in catalog:
        audio_metadata = validate_audio(audio_path_for(sound))
        response_metadata = validate_response_file(
            response_path_for(sound), tuple(sound["performedLyrics"])
        )
        report.append(
            {
                "number": sound["number"],
                "id": sound["id"],
                "displayName": sound["displayName"],
                "artistName": sound["band"],
                "genreName": sound["genreName"],
                "femaleSlutPride": sound["femaleSlutPride"],
                **audio_metadata,
                "model": response_metadata["model"],
                "generationAPI": response_metadata["endpoint"],
                "interactionID": response_metadata["interactionID"],
                "apiStepCount": response_metadata["stepCount"],
                "apiAudioBytes": response_metadata["apiAudioBytes"],
                "sourceAudio": response_metadata["sourceAudio"],
                "lyriaTimedLyricLines": response_metadata["timestampCount"],
                "lyriaResponseCharacters": response_metadata["characterCount"],
                "performedLyricLines": response_metadata["performedLineCount"],
                "matchedLyricLines": response_metadata["matchedLineCount"],
            }
        )
    return report


def remove_obsolete_assets() -> list[str]:
    """Remove replaced MP3/WAV masters and obsolete text-only response records."""
    removed: list[str] = []
    legacy_stems = [filename for _, filename in LEGACY_SOUND_IDENTITIES]
    obsolete_paths = [
        AUDIO_DIRECTORY / f"{filename}.wav" for filename in legacy_stems
    ]
    obsolete_paths += [
        LEGACY_MASTER_DIRECTORY / f"{filename}.mp3" for filename in legacy_stems
    ]
    obsolete_paths += [
        path
        for path in LYRIA_RESPONSE_DIRECTORY.glob("*.txt")
        if path.stem in {str(sound["id"]) for sound in SOUNDS}
    ]
    for path in obsolete_paths:
        if not path.exists():
            continue
        path.unlink()
        removed.append(str(path.relative_to(PROJECT_ROOT)))
    try:
        LEGACY_MASTER_DIRECTORY.rmdir()
    except OSError:
        pass
    return removed


def parse_arguments() -> argparse.Namespace:
    """Parse generation and verification options."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--force", action="store_true", help="Regenerate outputs that already validate."
    )
    parser.add_argument(
        "--max-attempts",
        type=int,
        default=5,
        help="Maximum REST attempts for each sound (default: 5).",
    )
    parser.add_argument(
        "--only",
        action="append",
        default=[],
        metavar="ID",
        help="Generate one catalog ID; repeat to select multiple IDs.",
    )
    parser.add_argument(
        "--verify-only",
        action="store_true",
        help="Validate all 100 loops without API calls or writes.",
    )
    parser.add_argument(
        "--workers",
        type=int,
        default=5,
        help="Concurrent Lyria requests (default: 5).",
    )
    return parser.parse_args()


def main() -> int:
    """Generate requested tracks and finalize metadata after full verification."""
    arguments = parse_arguments()
    if arguments.max_attempts < 1:
        raise GenerationError("--max-attempts must be at least 1")
    if arguments.workers < 1:
        raise GenerationError("--workers must be at least 1")
    for executable in ("ffmpeg", "ffprobe", "afconvert", "afinfo"):
        if shutil.which(executable) is None:
            raise GenerationError(f"Required executable is missing: {executable}")

    AUDIO_DIRECTORY.mkdir(parents=True, exist_ok=True)
    LYRIA_RESPONSE_DIRECTORY.mkdir(parents=True, exist_ok=True)
    CATALOG_PATH.parent.mkdir(parents=True, exist_ok=True)

    if arguments.verify_only:
        report = verify_catalog()
        log(json.dumps(report, indent=2))
        log(f"Verified {len(report)} exact looping AlarmKit tracks.")
        return 0

    known_ids = {str(sound["id"]) for sound in SOUNDS}
    unknown_ids = sorted(set(arguments.only) - known_ids)
    if unknown_ids:
        raise GenerationError(f"Unknown sound IDs: {', '.join(unknown_ids)}")
    selected = [
        sound
        for sound in SOUNDS
        if not arguments.only or sound["id"] in arguments.only
    ]
    api_key = os.environ.get("GEMINI_API_KEY", "")
    needs_generation = arguments.force or any(
        not outputs_are_valid(sound) for sound in selected
    )
    if needs_generation and not api_key:
        raise GenerationError("GEMINI_API_KEY is required to generate missing sounds")

    failures: list[str] = []
    results: list[dict[str, Any]] = []
    with concurrent.futures.ThreadPoolExecutor(max_workers=arguments.workers) as executor:
        future_map = {
            executor.submit(
                generate_sound,
                sound,
                api_key,
                arguments.max_attempts,
                arguments.force,
            ): sound
            for sound in selected
        }
        for future in concurrent.futures.as_completed(future_map):
            sound = future_map[future]
            try:
                results.append(future.result())
            except Exception as error:
                failure = f"{sound['number']:03d} {sound['displayName']}: {error}"
                failures.append(failure)
                log(f"FAIL  {failure}")

    write_catalog()
    if failures:
        log(f"Generation finished with {len(failures)} failure(s).")
        for failure in failures:
            log(f"  - {failure}")
        return 1

    verify_catalog(selected)
    if arguments.only:
        generated = sum(result["status"] == "generated" for result in results)
        log(f"Completed {len(results)} requested track(s); generated {generated}.")
        return 0

    report = verify_catalog()
    write_manifest()
    write_json_atomically(VERIFICATION_REPORT_PATH, report)
    removed = remove_obsolete_assets()
    generated = sum(result["status"] == "generated" for result in results)
    skipped = sum(result["status"] == "skipped" for result in results)
    total_bytes = sum(int(entry["fileBytes"]) for entry in report)
    log(
        f"SUCCESS: verified {len(report)} loops; generated {generated}, skipped {skipped}; "
        f"catalog audio is {total_bytes / 1024 / 1024:.1f} MiB; removed "
        f"{len(removed)} obsolete assets; wrote manifest, catalog, and verification report."
    )
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except GenerationError as error:
        log(f"ERROR: {error}")
        raise SystemExit(1) from error
