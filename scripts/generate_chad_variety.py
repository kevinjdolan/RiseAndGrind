#!/usr/bin/env python3
"""Generate the YAML-defined Chad variety set concurrently with Nano Banana Pro."""

from __future__ import annotations

import argparse
import base64
import concurrent.futures
import json
import mimetypes
import os
import subprocess
import threading
import time
import urllib.error
import urllib.request
from dataclasses import dataclass
from pathlib import Path

SOLID_BACKGROUND_RULE = """

Background and isolation requirements:
- Render the subject isolated on a perfectly uniform solid #00FF00 background.
- The background must be one flat color from edge to edge: no gradient, texture, vignette,
  scenery, floor, horizon, haze, reflections, or lighting variation.
- Keep the complete subject separated from every image edge with generous padding.
- Do not use #00FF00 anywhere on the subject, clothing, props, or accessories.
- Do not add a cast shadow, contact shadow, reflection, watermark, border, caption, or text.
- Do not generate transparency or a checkerboard pattern. The source must have an opaque,
  solid green background so Adobe Photoshop background removal can create the final alpha.
"""

API_ROOT = "https://generativelanguage.googleapis.com"
GENERATE_ENDPOINT = f"{API_ROOT}/v1beta/models/{{model}}:generateContent"
UPLOAD_ENDPOINT = f"{API_ROOT}/upload/v1beta/files"


@dataclass(frozen=True)
class VarietyJob:
    """One image-generation job derived from the companion YAML."""

    name: str
    references: tuple[Path, ...]
    prompt: str


@dataclass(frozen=True)
class UploadedReference:
    """A reusable Gemini Files API reference."""

    name: str
    uri: str
    mime_type: str


def parse_args() -> argparse.Namespace:
    """Parse command-line options."""
    parser = argparse.ArgumentParser()
    parser.add_argument("manifest", type=Path)
    parser.add_argument(
        "--asset-dir",
        type=Path,
        default=Path("scratch_data/chad_model_3"),
    )
    parser.add_argument(
        "--out-dir",
        type=Path,
        default=Path("scratch_data/chad_model_3/variety"),
    )
    parser.add_argument("--model", default="gemini-3-pro-image")
    parser.add_argument("--size", default="2K", choices=["1K", "2K", "4K"])
    parser.add_argument("--workers", type=int, default=4)
    parser.add_argument("--retries", type=int, default=3)
    parser.add_argument("--retry-delay", type=float, default=8.0)
    parser.add_argument("--start", type=int, default=0)
    parser.add_argument("--limit", type=int)
    parser.add_argument("--name")
    parser.add_argument("--status-name", default="generation-status.json")
    parser.add_argument("--dry-run", action="store_true")
    return parser.parse_args()


def load_yaml_with_ruby(path: Path) -> dict:
    """Load YAML through macOS Ruby's standard Psych parser."""
    ruby = (
        'require "yaml"; require "json"; '
        "document = YAML.safe_load(File.read(ARGV.fetch(0)), "
        "permitted_classes: [], aliases: false); "
        "STDOUT.write(JSON.generate(document))"
    )
    completed = subprocess.run(
        ["ruby", "-e", ruby, str(path)],
        check=True,
        capture_output=True,
        text=True,
    )
    return json.loads(completed.stdout)


def resolve_reference(asset_dir: Path, stem: str) -> Path:
    """Resolve one reference stem, including the set's legacy hyphenated filename."""
    candidates = [
        asset_dir / f"{stem}.png",
        asset_dir / f"{stem}.jpeg",
        asset_dir / f"{stem.replace('_serious', '-serious')}.png",
        asset_dir / f"{stem.replace('_serious', '-serious')}.jpeg",
    ]
    for candidate in candidates:
        if candidate.exists():
            return candidate
    raise FileNotFoundError(f"Missing reference image for {stem!r}")


def load_jobs(manifest: Path, asset_dir: Path) -> list[VarietyJob]:
    """Convert the companion YAML entries into validated generation jobs."""
    data = load_yaml_with_ruby(manifest)
    entries = data.get("proposed_images")
    if not isinstance(entries, list):
        raise ValueError("Manifest must contain a proposed_images list")

    jobs: list[VarietyJob] = []
    seen: set[str] = set()
    for entry in entries:
        name = entry["name"]
        if name in seen:
            raise ValueError(f"Duplicate proposed image name: {name}")
        seen.add(name)
        references = tuple(
            resolve_reference(asset_dir, stem) for stem in entry.get("references", [])
        )
        if not references:
            raise ValueError(f"{name} has no character references")
        prompt = f"{entry['prompt'].strip()}{SOLID_BACKGROUND_RULE}"
        jobs.append(VarietyJob(name=name, references=references, prompt=prompt))
    return jobs


def write_status(path: Path, status: dict[str, dict]) -> None:
    """Persist generation status atomically for resumption and auditing."""
    temporary = path.with_suffix(".tmp")
    temporary.write_text(json.dumps(status, indent=2, sort_keys=True) + "\n")
    temporary.replace(path)


def api_key() -> str:
    """Return the configured Gemini API key without logging it."""
    key = os.environ.get("GEMINI_API_KEY")
    if not key:
        raise RuntimeError("GEMINI_API_KEY is not set")
    return key


def upload_reference(path: Path) -> UploadedReference:
    """Upload one reusable reference with the Gemini Files API."""
    key = api_key()
    mime_type = mimetypes.guess_type(path)[0] or "image/png"
    file_size = path.stat().st_size
    start_request = urllib.request.Request(
        f"{UPLOAD_ENDPOINT}?key={key}",
        data=json.dumps({"file": {"display_name": path.stem}}).encode("utf-8"),
        headers={
            "Content-Type": "application/json",
            "X-Goog-Upload-Protocol": "resumable",
            "X-Goog-Upload-Command": "start",
            "X-Goog-Upload-Header-Content-Length": str(file_size),
            "X-Goog-Upload-Header-Content-Type": mime_type,
        },
        method="POST",
    )
    with urllib.request.urlopen(start_request, timeout=60) as response:
        upload_url = response.headers.get("X-Goog-Upload-URL")
    if not upload_url:
        raise RuntimeError(f"Files API did not return an upload URL for {path.name}")

    upload_request = urllib.request.Request(
        upload_url,
        data=path.read_bytes(),
        headers={
            "Content-Length": str(file_size),
            "Content-Type": mime_type,
            "X-Goog-Upload-Offset": "0",
            "X-Goog-Upload-Command": "upload, finalize",
        },
        method="POST",
    )
    with urllib.request.urlopen(upload_request, timeout=300) as response:
        payload = json.load(response)
    uploaded = payload["file"]
    return UploadedReference(
        name=uploaded["name"],
        uri=uploaded["uri"],
        mime_type=uploaded.get("mimeType", mime_type),
    )


def reference_is_active(reference: UploadedReference) -> bool:
    """Return whether a cached Gemini file is still available."""
    request = urllib.request.Request(
        f"{API_ROOT}/v1beta/{reference.name}?key={api_key()}",
        method="GET",
    )
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            payload = json.load(response)
    except urllib.error.HTTPError:
        return False
    return payload.get("state", "ACTIVE") == "ACTIVE"


def load_reference_cache(path: Path) -> dict[str, UploadedReference]:
    """Load a prior file-URI cache if present."""
    if not path.exists():
        return {}
    payload = json.loads(path.read_text())
    return {
        source_path: UploadedReference(**reference)
        for source_path, reference in payload.items()
    }


def write_reference_cache(
    path: Path,
    references: dict[str, UploadedReference],
) -> None:
    """Persist reusable file URIs without storing credentials."""
    payload = {
        source_path: {
            "name": reference.name,
            "uri": reference.uri,
            "mime_type": reference.mime_type,
        }
        for source_path, reference in sorted(references.items())
    }
    temporary = path.with_suffix(".tmp")
    temporary.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n")
    temporary.replace(path)


def prepare_references(
    jobs: list[VarietyJob],
    cache_path: Path,
    workers: int,
) -> dict[Path, UploadedReference]:
    """Validate cached references and upload missing ones concurrently."""
    paths = sorted({path for job in jobs for path in job.references})
    cached = load_reference_cache(cache_path)
    ready: dict[Path, UploadedReference] = {}
    missing: list[Path] = []
    cached_paths = {
        path: cached.get(str(path.resolve()))
        for path in paths
    }
    with concurrent.futures.ThreadPoolExecutor(
        max_workers=min(workers, len(paths))
    ) as executor:
        validation_paths = {
            executor.submit(reference_is_active, reference): path
            for path, reference in cached_paths.items()
            if reference is not None
        }
        active_paths = {
            path
            for future, path in validation_paths.items()
            if future.result()
        }
    for path, reference in cached_paths.items():
        if reference is not None and path in active_paths:
            ready[path] = reference
        else:
            missing.append(path)

    if missing:
        print(f"Uploading {len(missing)} reusable character references...", flush=True)
        with concurrent.futures.ThreadPoolExecutor(
            max_workers=min(workers, len(missing))
        ) as executor:
            future_paths = {
                executor.submit(upload_reference, path): path for path in missing
            }
            for future in concurrent.futures.as_completed(future_paths):
                path = future_paths[future]
                ready[path] = future.result()
                print(f"uploaded {path.name}", flush=True)

    write_reference_cache(
        cache_path,
        {str(path.resolve()): reference for path, reference in ready.items()},
    )
    return ready


def generate_from_references(
    references: tuple[UploadedReference, ...],
    output: Path,
    model: str,
    prompt: str,
    size: str,
) -> None:
    """Generate one image from uploaded references with Nano Banana Pro."""
    parts = [
        {
            "file_data": {
                "mime_type": reference.mime_type,
                "file_uri": reference.uri,
            }
        }
        for reference in references
    ]
    parts.append({"text": prompt})
    body = {
        "contents": [{"role": "user", "parts": parts}],
        "generationConfig": {
            "responseModalities": ["IMAGE"],
            "imageConfig": {"aspectRatio": "1:1", "imageSize": size},
        },
    }
    request = urllib.request.Request(
        f"{GENERATE_ENDPOINT.format(model=model)}?key={api_key()}",
        data=json.dumps(body).encode("utf-8"),
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    with urllib.request.urlopen(request, timeout=600) as response:
        payload = json.load(response)
    candidates = payload.get("candidates") or []
    if not candidates:
        raise RuntimeError(f"No generation candidate returned: {json.dumps(payload)[:500]}")
    for part in candidates[0].get("content", {}).get("parts", []):
        blob = part.get("inlineData") or part.get("inline_data")
        if blob and blob.get("data"):
            output.write_bytes(base64.b64decode(blob["data"]))
            return
    raise RuntimeError(
        f"Generation returned no image: {json.dumps(candidates[0])[:500]}"
    )


def convert_to_jpeg(source: Path, output: Path) -> None:
    """Convert the model response into a correctly encoded opaque JPEG source."""
    subprocess.run(
        [
            "sips",
            "-s",
            "format",
            "jpeg",
            "-s",
            "formatOptions",
            "100",
            str(source),
            "--out",
            str(output),
        ],
        check=True,
        capture_output=True,
        text=True,
    )


def generate_one(
    job: VarietyJob,
    out_dir: Path,
    model: str,
    size: str,
    retries: int,
    retry_delay: float,
    uploaded_references: dict[Path, UploadedReference],
) -> tuple[str, bool, str]:
    """Generate one source render, retrying transient API failures."""
    output = out_dir / f"{job.name}.jpeg"
    if output.exists() and output.stat().st_size > 0:
        return job.name, True, "existing"

    for attempt in range(1, retries + 1):
        partial = out_dir / f".{job.name}.partial.png"
        partial.unlink(missing_ok=True)
        try:
            generate_from_references(
                references=tuple(
                    uploaded_references[path] for path in job.references
                ),
                output=partial,
                model=model,
                prompt=job.prompt,
                size=size,
            )
        except Exception as error:
            detail = repr(error)
        else:
            detail = ""
        if partial.exists() and partial.stat().st_size > 0:
            convert_to_jpeg(partial, output)
            partial.unlink(missing_ok=True)
            return job.name, True, f"generated on attempt {attempt}"
        partial.unlink(missing_ok=True)
        if attempt < retries:
            time.sleep(retry_delay * attempt)
    return job.name, False, f"failed after {retries} attempts: {detail}"


def run_jobs(args: argparse.Namespace, jobs: list[VarietyJob]) -> int:
    """Run selected jobs concurrently and maintain a resumable status file."""
    args.out_dir.mkdir(parents=True, exist_ok=True)
    status_path = args.out_dir / args.status_name
    status: dict[str, dict] = {}
    lock = threading.Lock()

    if args.name:
        jobs = [job for job in jobs if job.name == args.name]
        if not jobs:
            raise ValueError(f"No proposed image named {args.name!r}")
    if args.start:
        jobs = jobs[args.start :]
    if args.limit is not None:
        jobs = jobs[: args.limit]

    if args.dry_run:
        for job in jobs:
            print(
                json.dumps(
                    {
                        "name": job.name,
                        "references": [str(path) for path in job.references],
                        "output": str(args.out_dir / f"{job.name}.jpeg"),
                    }
                )
            )
        return 0

    uploaded_references = prepare_references(
        jobs,
        args.out_dir / "gemini-reference-cache.json",
        args.workers,
    )
    with concurrent.futures.ThreadPoolExecutor(max_workers=args.workers) as executor:
        future_jobs = {
            executor.submit(
                generate_one,
                job,
                args.out_dir,
                args.model,
                args.size,
                args.retries,
                args.retry_delay,
                uploaded_references,
            ): job
            for job in jobs
        }
        for completed, future in enumerate(
            concurrent.futures.as_completed(future_jobs), start=1
        ):
            job = future_jobs[future]
            try:
                name, success, detail = future.result()
            except Exception as error:
                name, success, detail = job.name, False, repr(error)
            with lock:
                status[name] = {"success": success, "detail": detail}
                write_status(status_path, status)
            print(
                f"[{completed}/{len(jobs)}] {name}: {detail}",
                flush=True,
            )

    failures = [name for name, result in status.items() if not result["success"]]
    if failures:
        print(f"{len(failures)} generation jobs failed", flush=True)
        return 1
    return 0


def main() -> int:
    """Load, filter, and execute the Chad variety manifest."""
    args = parse_args()
    jobs = load_jobs(args.manifest.resolve(), args.asset_dir.resolve())
    return run_jobs(args, jobs)


if __name__ == "__main__":
    raise SystemExit(main())
