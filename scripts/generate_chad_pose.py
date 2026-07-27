#!/usr/bin/env python3
"""Generate a new Chad pose from an existing reference render via Gemini image models.

Usage:
    python3 scripts/generate_chad_pose.py REF_IMAGE OUT_IMAGE [--model MODEL] [--prompt-file FILE]

Reads GEMINI_API_KEY from the environment.
"""

from __future__ import annotations

import argparse
import base64
import json
import mimetypes
import os
import sys
import urllib.error
import urllib.request

ENDPOINT = "https://generativelanguage.googleapis.com/v1beta/models/{model}:generateContent"

DEFAULT_PROMPT = """\
Using the attached reference render as the exact character and art style, produce a new
render of the same figure in the bottom position of a goblet squat, holding a smartphone
in place of a kettlebell.

This is an exercise-form instruction illustration for a fitness app. It must depict
textbook-correct squat mechanics:

- Feet flat on the ground, whole sole in contact, heels firmly down, never rising.
- Stance slightly wider than shoulder width, toes turned out roughly 20 degrees.
- Hips travelled back and down; thigh at or just below parallel with the ground, hip
  crease level with or slightly below the top of the knee.
- Knees tracking outward in line with the toes, directly over the midfoot, not collapsing inward.
- Shins near vertical, weight balanced over the middle of the foot.
- Torso tall and nearly upright, chest lifted and open.
- Spine neutral with its natural lumbar curve; no rounding of the lower back, no excessive arch.
- Head and neck neutral, gaze level and forward.
- Both elbows tucked down close to the ribs, pointing at the floor, positioned inside the knees.
- Both hands cupped together around a red smartphone held vertically against the sternum at
  chest height, exactly as one would hold a kettlebell in the goblet position.

Wardrobe: the figure wears fitted black athletic compression shorts reaching mid-thigh.

Style: match the reference exactly - smooth matte light-grey sculpted statue material,
monochrome greyscale body, soft studio lighting from the upper front, pure black background,
the smartphone the only saturated colour. Same face, same beard, same slicked-back hair,
same muscular proportions.

Camera: three-quarter front view from a slightly lowered angle, full body head to feet
inside the frame with margin, subject centred, square image.
"""


def load_image_part(path: str) -> dict:
    mime = mimetypes.guess_type(path)[0] or "image/png"
    with open(path, "rb") as fh:
        data = base64.b64encode(fh.read()).decode("ascii")
    return {"inline_data": {"mime_type": mime, "data": data}}


def generate(refs: list[str], out: str, model: str, prompt: str, size: str) -> int:
    key = os.environ.get("GEMINI_API_KEY")
    if not key:
        print("GEMINI_API_KEY is not set", file=sys.stderr)
        return 2

    parts = [load_image_part(r) for r in refs]
    parts.append({"text": prompt})
    body = {
        "contents": [{"role": "user", "parts": parts}],
        "generationConfig": {
            "responseModalities": ["IMAGE"],
            "imageConfig": {"aspectRatio": "1:1", "imageSize": size},
        },
    }

    req = urllib.request.Request(
        ENDPOINT.format(model=model) + f"?key={key}",
        data=json.dumps(body).encode("utf-8"),
        headers={"Content-Type": "application/json"},
        method="POST",
    )

    try:
        with urllib.request.urlopen(req, timeout=300) as resp:
            payload = json.load(resp)
    except urllib.error.HTTPError as exc:
        print(f"HTTP {exc.code}", file=sys.stderr)
        print(exc.read().decode("utf-8", "replace")[:4000], file=sys.stderr)
        return 1

    candidates = payload.get("candidates") or []
    if not candidates:
        print("No candidates returned:", json.dumps(payload)[:2000], file=sys.stderr)
        return 1

    cand = candidates[0]
    for part in cand.get("content", {}).get("parts", []):
        blob = part.get("inlineData") or part.get("inline_data")
        if blob and blob.get("data"):
            with open(out, "wb") as fh:
                fh.write(base64.b64decode(blob["data"]))
            print(f"wrote {out}")
            return 0
        if part.get("text"):
            print("model text:", part["text"][:2000], file=sys.stderr)

    print(f"finishReason={cand.get('finishReason')}", file=sys.stderr)
    print(json.dumps(cand.get("safetyRatings", []), indent=2), file=sys.stderr)
    return 1


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("out")
    ap.add_argument("--ref", action="append", default=[], help="reference image (repeatable)")
    ap.add_argument("--model", default="gemini-3-pro-image")
    ap.add_argument("--prompt-file")
    ap.add_argument("--size", default="2K", choices=["1K", "2K", "4K"])
    args = ap.parse_args()

    prompt = DEFAULT_PROMPT
    if args.prompt_file:
        with open(args.prompt_file) as fh:
            prompt = fh.read()

    return generate(args.ref, args.out, args.model, prompt, args.size)


if __name__ == "__main__":
    raise SystemExit(main())
