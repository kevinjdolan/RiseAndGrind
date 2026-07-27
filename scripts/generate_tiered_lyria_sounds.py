#!/usr/bin/env python3
"""Generate, master, compress, and verify the five-tier alarm music library."""

from __future__ import annotations

import argparse
import base64
import concurrent.futures
import hashlib
import json
import os
from pathlib import Path
import random
import re
import shutil
import subprocess
import tempfile
import threading
import time
from typing import Any
import urllib.error
import urllib.request

from tiered_lyria_catalog import CATALOG, TIER_PROFILES


MODEL = "lyria-3-clip-preview"
ENDPOINT = "https://generativelanguage.googleapis.com/v1beta/interactions"
TRACK_SECONDS = 29.0
SOURCE_MINIMUM_SECONDS = 29.0
APP_SAMPLE_RATE = 22_050
APP_SAMPLE_COUNT = round(TRACK_SECONDS * APP_SAMPLE_RATE)
LOOP_CROSSFADE_SECONDS = 0.5
MAXIMUM_APP_BYTES = 410_000

PROJECT_ROOT = Path(__file__).resolve().parent.parent
APP_AUDIO_DIRECTORY = PROJECT_ROOT / "RiseAndGrind" / "Resources" / "Sounds"
MANIFEST_PATH = APP_AUDIO_DIRECTORY / "manifest.json"
SCRATCH_DIRECTORY = PROJECT_ROOT / "scratch_data"
MASTER_DIRECTORY = SCRATCH_DIRECTORY / "TieredMusicMasters"
RESPONSE_DIRECTORY = SCRATCH_DIRECTORY / "TieredLyriaResponses"
CATALOG_PATH = SCRATCH_DIRECTORY / "tiered_music_catalog.json"
VERIFICATION_PATH = RESPONSE_DIRECTORY / "verification.json"
PRINT_LOCK = threading.Lock()


class GenerationError(RuntimeError):
    """Report a generation, mastering, or validation failure."""


def log(message: str) -> None:
    """Print one complete progress line safely across worker threads."""
    with PRINT_LOCK:
        print(message, flush=True)


def run(command: list[str]) -> subprocess.CompletedProcess[str]:
    """Run a required local media command and surface its useful error output."""
    result = subprocess.run(command, check=False, capture_output=True, text=True)
    if result.returncode != 0:
        detail = (result.stderr or result.stdout)[-2_000:]
        raise GenerationError(f"{' '.join(command[:3])} failed: {detail}")
    return result


def probe_audio(path: Path) -> dict[str, Any]:
    """Return normalized metadata for the first audio stream."""
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


def make_prompt(track: dict[str, Any]) -> str:
    """Build a tier-specific Lyria prompt for an original looping alarm song."""
    lyrics = "\n".join(f"- {line}" for line in track["performedLyrics"])
    return (
        f'Create an original high-fidelity 30-second song titled "{track["displayName"]}" '
        f'by the fictional act "{track["artistName"]}".\n'
        f'INTENSITY TIER: {track["intensityName"]}.\n'
        f'GENRE: {track["genreName"]}; {track["genreDescription"]}.\n'
        f'TEMPO: {track["bpmRange"]}.\n'
        f'ENERGY: {track["energyDirection"]}.\n'
        "Use a clear original melody and production appropriate to the stated genre. "
        "Do not imitate any existing artist, song, melody, or recording. Keep the mix "
        "full-range and clean; post-production will create the compact phone version.\n"
        "Author it as a continuous loop: begin immediately, never fade or stop, and return "
        "from 27.5–30.0 seconds to the opening groove, harmony, and instrumentation.\n"
        "Sing each short line once, clearly and in order. Do not add or repeat words:\n"
        f"{lyrics}"
    )


def extract_result(payload: dict[str, Any]) -> tuple[bytes, dict[str, Any]]:
    """Extract audio and non-secret evidence from a Lyria interaction response."""
    audio: bytes | None = None
    text_blocks: list[str] = []
    for step in payload.get("steps") or []:
        if step.get("type") != "model_output":
            continue
        for content in step.get("content") or []:
            if content.get("type") == "audio" and content.get("data"):
                audio = base64.b64decode(content["data"])
            elif content.get("type") == "text" and content.get("text"):
                text_blocks.append(str(content["text"]).strip())
    if payload.get("error"):
        raise GenerationError(f"Lyria API error: {str(payload['error'])[:500]}")
    if not audio:
        raise GenerationError("Lyria response contained no audio")
    return audio, {
        "model": MODEL,
        "endpoint": ENDPOINT,
        "interactionID": payload.get("id"),
        "stepCount": len(payload.get("steps") or []),
        "modelText": "\n\n".join(text_blocks),
        "audioByteCount": len(audio),
    }


def request_audio(
    prompt: str,
    api_key: str,
    max_attempts: int,
    label: str,
) -> tuple[bytes, dict[str, Any]]:
    """Request one Lyria clip with bounded retries for transient failures."""
    body = json.dumps({"model": MODEL, "input": prompt}).encode("utf-8")
    for attempt in range(1, max_attempts + 1):
        request = urllib.request.Request(
            ENDPOINT,
            data=body,
            method="POST",
            headers={
                "Content-Type": "application/json",
                "x-goog-api-key": api_key,
                "User-Agent": "RiseAndGrind-TieredMusic/3.0",
            },
        )
        try:
            with urllib.request.urlopen(request, timeout=900) as response:
                return extract_result(json.loads(response.read()))
        except urllib.error.HTTPError as error:
            detail = error.read().decode("utf-8", errors="replace")[:500]
            retryable = error.code in {408, 409, 429, 500, 502, 503, 504} or (
                error.code == 400 and "content_blocked" in detail
            )
            reason = f"HTTP {error.code}: {detail}"
        except (urllib.error.URLError, TimeoutError, json.JSONDecodeError) as error:
            retryable = True
            reason = f"{type(error).__name__}: {error}"
        except (GenerationError, ValueError, TypeError) as error:
            retryable = True
            reason = str(error)
        if not retryable or attempt == max_attempts:
            raise GenerationError(f"{label} failed after {attempt} attempt(s): {reason}")
        delay = min(45.0, 2 ** (attempt - 1) * 2.0 + random.random() * 2.0)
        log(f"RETRY {label}: {reason}; waiting {delay:.1f}s")
        time.sleep(delay)
    raise AssertionError("retry loop exited unexpectedly")


def master_loop(source: Path, destination: Path, work_directory: Path) -> None:
    """Create an exact 29-second mono IMA4 CAF optimized for phone playback."""
    source_metadata = probe_audio(source)
    if source_metadata["duration"] < SOURCE_MINIMUM_SECONDS:
        raise GenerationError(
            f"Source was only {source_metadata['duration']:.3f} seconds"
        )
    pcm_path = work_directory / "app-master.wav"
    source_samples = round(30.0 * APP_SAMPLE_RATE)
    crossfade_samples = round(LOOP_CROSSFADE_SECONDS * APP_SAMPLE_RATE)
    bridge_end = APP_SAMPLE_COUNT + crossfade_samples
    tier_filter = (
        f"aresample={APP_SAMPLE_RATE},pan=mono|c0=0.707*FL+0.707*FR,"
        "highpass=f=90,lowpass=f=10000,equalizer=f=2800:t=q:w=1:g=2,"
        "acompressor=threshold=0.10:ratio=4:attack=4:release=80:makeup=3,"
        "alimiter=limit=0.78:attack=5:release=50:level=false:latency=true,"
        f"apad=whole_len={source_samples},atrim=end_sample={source_samples},"
        "asetpts=N/SR/TB"
    )
    filter_graph = (
        f"[0:a]{tier_filter},asplit=3[body_source][tail_source][head_source];"
        f"[body_source]atrim=start_sample={crossfade_samples}:"
        f"end_sample={APP_SAMPLE_COUNT},asetpts=N/SR/TB[body];"
        f"[tail_source]atrim=start_sample={APP_SAMPLE_COUNT}:"
        f"end_sample={bridge_end},asetpts=N/SR/TB[tail];"
        f"[head_source]atrim=start_sample=0:end_sample={crossfade_samples},"
        "asetpts=N/SR/TB[head];"
        f"[tail][head]acrossfade=d={LOOP_CROSSFADE_SECONDS}:c1=tri:c2=tri[bridge];"
        f"[body][bridge]concat=n=2:v=0:a=1,atrim=end_sample={APP_SAMPLE_COUNT},"
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
            str(APP_SAMPLE_RATE),
            "-ac",
            "1",
            "-c:a",
            "pcm_s16le",
            str(pcm_path),
        ]
    )
    run(["afconvert", str(pcm_path), str(destination), "-d", "ima4", "-f", "caff"])


def validate_master(path: Path) -> dict[str, Any]:
    """Validate an untouched high-fidelity model master."""
    if not path.is_file() or path.stat().st_size == 0:
        raise GenerationError(f"Missing high-fidelity master: {path}")
    metadata = probe_audio(path)
    if metadata["duration"] < SOURCE_MINIMUM_SECONDS:
        raise GenerationError(f"High-fidelity master is too short: {path}")
    metadata["sha256"] = hashlib.sha256(path.read_bytes()).hexdigest()
    return metadata


def validate_app_audio(path: Path) -> dict[str, Any]:
    """Validate duration, codec, sample rate, channels, and compact file size."""
    if not path.is_file() or path.stat().st_size == 0:
        raise GenerationError(f"Missing app audio: {path}")
    afinfo = run(["afinfo", str(path)]).stdout
    duration_match = re.search(r"estimated duration:\s+([\d.]+) sec", afinfo)
    frames_match = re.search(r"audio\s+(\d+) valid frames", afinfo)
    sample_rate_match = re.search(r"1 ch,\s+(\d+) Hz,\s+ima4", afinfo)
    if not duration_match or not frames_match or not sample_rate_match:
        raise GenerationError(f"Unable to parse compact CAF metadata: {path}")
    duration = float(duration_match.group(1))
    sample_count = int(frames_match.group(1))
    sample_rate = int(sample_rate_match.group(1))
    if sample_rate != APP_SAMPLE_RATE:
      raise GenerationError(f"Unexpected sample rate in {path}")
    if duration != TRACK_SECONDS or sample_count != APP_SAMPLE_COUNT:
      raise GenerationError(f"App audio is not exactly 29 seconds: {path}")
    file_size = path.stat().st_size
    if file_size > MAXIMUM_APP_BYTES:
      raise GenerationError(f"App audio exceeds {MAXIMUM_APP_BYTES} bytes: {path}")
    return {
        "duration": duration,
        "sampleCount": sample_count,
        "sample_rate": sample_rate,
        "channels": 1,
        "codec_name": "ima4",
        "container": "caf",
        "size": file_size,
        "sha256": hashlib.sha256(path.read_bytes()).hexdigest(),
    }


def master_path(track: dict[str, Any]) -> Path:
    """Return the high-fidelity master path for one catalog track."""
    return MASTER_DIRECTORY / track["intensityTier"] / f"{track['filename']}.mp3"


def app_path(track: dict[str, Any]) -> Path:
    """Return the compact bundled CAF path for one catalog track."""
    return APP_AUDIO_DIRECTORY / f"{track['filename']}.caf"


def response_path(track: dict[str, Any]) -> Path:
    """Return the generation-evidence path for one catalog track."""
    return RESPONSE_DIRECTORY / track["intensityTier"] / f"{track['id']}.json"


def outputs_are_valid(track: dict[str, Any]) -> bool:
    """Return whether one master, app loop, and response record are complete."""
    try:
        validate_master(master_path(track))
        validate_app_audio(app_path(track))
        payload = json.loads(response_path(track).read_text(encoding="utf-8"))
        return payload.get("model") == MODEL and bool(payload.get("interactionID"))
    except (GenerationError, OSError, ValueError, TypeError, json.JSONDecodeError):
        return False


def generate_track(
    track: dict[str, Any],
    api_key: str,
    max_attempts: int,
    force: bool,
) -> dict[str, Any]:
    """Generate or resume one track and atomically install its derived artifacts."""
    destination_master = master_path(track)
    destination_app = app_path(track)
    destination_response = response_path(track)
    label = f"{track['intensityName']} {track['number']:02d} {track['displayName']}"
    if not force and outputs_are_valid(track):
        log(f"SKIP  {label}")
        return {"id": track["id"], "status": "skipped"}

    destination_master.parent.mkdir(parents=True, exist_ok=True)
    destination_response.parent.mkdir(parents=True, exist_ok=True)
    log(f"START {label}")
    with tempfile.TemporaryDirectory(prefix="rise-tiered-lyria-") as temporary:
        work_directory = Path(temporary)
        pending_master = work_directory / "master.mp3"
        pending_app = work_directory / destination_app.name
        pending_response = work_directory / destination_response.name

        if not force and destination_master.is_file() and destination_response.is_file():
            shutil.copy2(destination_master, pending_master)
            response_record = json.loads(destination_response.read_text(encoding="utf-8"))
            source_metadata = validate_master(pending_master)
        else:
            source_metadata = {}
            for source_attempt in range(1, max_attempts + 1):
                audio, response_record = request_audio(
                    make_prompt(track), api_key, max_attempts, label
                )
                pending_master.write_bytes(audio)
                try:
                    source_metadata = validate_master(pending_master)
                    break
                except GenerationError:
                    if source_attempt == max_attempts:
                        raise
                    log(
                        f"RETRY {label}: generated source was shorter than "
                        f"{SOURCE_MINIMUM_SECONDS:.1f}s"
                    )
        response_record["sourceAudio"] = {
            key: source_metadata[key]
            for key in ("duration", "size", "codec_name", "sample_rate", "channels", "sha256")
        }
        response_record["trackID"] = track["id"]
        response_record["prompt"] = make_prompt(track)
        pending_response.write_text(
            json.dumps(response_record, indent=2) + "\n", encoding="utf-8"
        )
        pending_master.replace(destination_master)
        pending_response.replace(destination_response)
        master_loop(destination_master, pending_app, work_directory)
        app_metadata = validate_app_audio(pending_app)
        pending_app.replace(destination_app)
    log(
        f"DONE  {label}: master {source_metadata['size'] / 1024:.0f} KiB; "
        f"app {app_metadata['size'] / 1024:.0f} KiB"
    )
    return {"id": track["id"], "status": "generated"}


def manifest_track(track: dict[str, Any]) -> dict[str, Any]:
    """Build one runtime manifest record."""
    filename = f"{track['filename']}.caf"
    return {
        "id": track["id"],
        "intensityTier": track["intensityTier"],
        "displayName": track["displayName"],
        "artistName": track["artistName"],
        "genreName": track["genreName"],
        "genreDescription": track["genreDescription"],
        "performedLyrics": track["performedLyrics"],
        "alarmFilename": filename,
        "previewFilename": filename,
        "defaultSelected": True,
        "durationSeconds": TRACK_SECONDS,
        "loopAuthored": True,
        "model": MODEL,
    }


def write_json(path: Path, payload: Any) -> None:
    """Write indented JSON atomically."""
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")
    temporary.replace(path)


def verify_catalog() -> list[dict[str, Any]]:
    """Verify every generated artifact and return a compact evidence report."""
    report: list[dict[str, Any]] = []
    for track in CATALOG:
        report.append(
            {
                "id": track["id"],
                "intensityTier": track["intensityTier"],
                "displayName": track["displayName"],
                "artistName": track["artistName"],
                "genreName": track["genreName"],
                "master": validate_master(master_path(track)),
                "app": validate_app_audio(app_path(track)),
            }
        )
    return report


def finalize_catalog() -> None:
    """Write schema-3 metadata only after all 320 songs validate."""
    report = verify_catalog()
    tier_counts = {
        tier.identifier: sum(
            track["intensityTier"] == tier.identifier for track in CATALOG
        )
        for tier in TIER_PROFILES
    }
    manifest = {
        "schemaVersion": 3,
        "trackCount": len(CATALOG),
        "tierCounts": tier_counts,
        "model": MODEL,
        "generationAPI": ENDPOINT,
        "durationSeconds": TRACK_SECONDS,
        "loopingPreview": True,
        "audioFormat": {
            "container": "caf",
            "codec": "ima4",
            "sampleRate": APP_SAMPLE_RATE,
            "channels": 1,
        },
        "tracks": [manifest_track(track) for track in CATALOG],
    }
    write_json(CATALOG_PATH, list(CATALOG))
    write_json(VERIFICATION_PATH, report)
    write_json(MANIFEST_PATH, manifest)


def parse_arguments() -> argparse.Namespace:
    """Parse resumable catalog-generation options."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--force", action="store_true")
    parser.add_argument("--verify-only", action="store_true")
    parser.add_argument("--only", action="append", default=[], metavar="ID")
    parser.add_argument(
        "--only-tier",
        choices=[tier.identifier for tier in TIER_PROFILES],
    )
    parser.add_argument("--limit", type=int)
    parser.add_argument("--workers", type=int, default=6)
    parser.add_argument("--max-attempts", type=int, default=5)
    return parser.parse_args()


def main() -> int:
    """Generate selected tracks and finalize when the full catalog is complete."""
    arguments = parse_arguments()
    for executable in ("ffmpeg", "ffprobe", "afconvert", "afinfo"):
        if shutil.which(executable) is None:
            raise GenerationError(f"Required executable is missing: {executable}")
    if arguments.workers < 1 or arguments.max_attempts < 1:
        raise GenerationError("Workers and attempts must be positive")
    if arguments.verify_only:
        finalize_catalog()
        log("Verified and finalized all 320 tiered tracks.")
        return 0

    selected = [
        track
        for track in CATALOG
        if (not arguments.only or track["id"] in arguments.only)
        and (
            not arguments.only_tier
            or track["intensityTier"] == arguments.only_tier
        )
    ]
    if arguments.limit is not None:
        selected = selected[: max(0, arguments.limit)]
    known_ids = {track["id"] for track in CATALOG}
    unknown_ids = sorted(set(arguments.only) - known_ids)
    if unknown_ids:
        raise GenerationError(f"Unknown track IDs: {', '.join(unknown_ids)}")
    api_key = os.environ.get("GEMINI_API_KEY", "")
    if any(arguments.force or not outputs_are_valid(track) for track in selected):
        if not api_key:
            raise GenerationError("GEMINI_API_KEY is required for missing tracks")

    failures: list[str] = []
    results: list[dict[str, Any]] = []
    APP_AUDIO_DIRECTORY.mkdir(parents=True, exist_ok=True)
    with concurrent.futures.ThreadPoolExecutor(max_workers=arguments.workers) as executor:
        future_map = {
            executor.submit(
                generate_track,
                track,
                api_key,
                arguments.max_attempts,
                arguments.force,
            ): track
            for track in selected
        }
        for future in concurrent.futures.as_completed(future_map):
            track = future_map[future]
            try:
                results.append(future.result())
            except Exception as error:
                failure = f"{track['id']}: {error}"
                failures.append(failure)
                log(f"FAIL  {failure}")
    write_json(CATALOG_PATH, list(CATALOG))
    if failures:
        log(f"Generation completed with {len(failures)} failure(s).")
        return 1
    if all(outputs_are_valid(track) for track in CATALOG):
        finalize_catalog()
        total_bytes = sum(app_path(track).stat().st_size for track in CATALOG)
        log(
            f"SUCCESS: verified 320 tracks in five tiers; app audio "
            f"{total_bytes / 1024 / 1024:.1f} MiB."
        )
    else:
        log(f"Completed {len(results)} selected track(s); full catalog remains resumable.")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except GenerationError as error:
        log(f"ERROR: {error}")
        raise SystemExit(1) from error
