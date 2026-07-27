#!/usr/bin/env python3
"""Remove chroma-green edge spill from Photoshop-generated Chad cutouts."""

from __future__ import annotations

import argparse
from pathlib import Path

import numpy
from PIL import Image


def parse_args() -> argparse.Namespace:
    """Parse command-line options."""
    parser = argparse.ArgumentParser()
    parser.add_argument("directory", type=Path)
    parser.add_argument("--threshold", type=int, default=4)
    return parser.parse_args()


def despill(path: Path, threshold: int) -> int:
    """Clamp green-dominant subject pixels while preserving the alpha matte."""
    image = Image.open(path).convert("RGBA")
    pixels = numpy.asarray(image).copy()
    alpha = pixels[:, :, 3]
    red = pixels[:, :, 0].astype(numpy.int16)
    green = pixels[:, :, 1].astype(numpy.int16)
    blue = pixels[:, :, 2].astype(numpy.int16)
    neutral_ceiling = numpy.maximum(red, blue)
    contaminated = (
        (alpha > 0)
        & ((green - neutral_ceiling) > threshold)
    )
    changed = int(numpy.count_nonzero(contaminated))
    pixels[:, :, 1] = numpy.where(
        contaminated,
        neutral_ceiling,
        pixels[:, :, 1],
    ).astype(numpy.uint8)
    pixels[alpha == 0, :3] = 0
    Image.fromarray(pixels, mode="RGBA").save(path, compress_level=6)
    return changed


def main() -> int:
    """Despill every PNG cutout in the requested directory."""
    args = parse_args()
    paths = sorted(args.directory.glob("chad_*.png"))
    if not paths:
        raise SystemExit(f"No Chad PNGs found in {args.directory}")
    for index, path in enumerate(paths, start=1):
        changed = despill(path, args.threshold)
        print(f"[{index}/{len(paths)}] {path.name}: despilled {changed} pixels")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
