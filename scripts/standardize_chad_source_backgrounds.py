#!/usr/bin/env python3
"""Rebuild Chad JPEG sources on a perfectly flat chroma-green background."""

from __future__ import annotations

import argparse
from pathlib import Path

from PIL import Image

BACKGROUND = (0, 255, 0, 255)


def parse_args() -> argparse.Namespace:
    """Parse command-line options."""
    parser = argparse.ArgumentParser()
    parser.add_argument("directory", type=Path)
    parser.add_argument("--quality", type=int, default=100)
    return parser.parse_args()


def rebuild_source(png_path: Path, quality: int) -> Path:
    """Composite one Photoshop cutout onto a uniform green JPEG source."""
    cutout = Image.open(png_path).convert("RGBA")
    background = Image.new("RGBA", cutout.size, BACKGROUND)
    background.alpha_composite(cutout)
    output = png_path.with_suffix(".jpeg")
    background.convert("RGB").save(
        output,
        format="JPEG",
        quality=quality,
        subsampling=0,
    )
    return output


def main() -> int:
    """Standardize every Photoshop-processed Chad source in a directory."""
    args = parse_args()
    paths = sorted(args.directory.glob("chad_*.png"))
    if not paths:
        raise SystemExit(f"No Chad PNGs found in {args.directory}")
    for index, path in enumerate(paths, start=1):
        output = rebuild_source(path, args.quality)
        print(f"[{index}/{len(paths)}] rebuilt {output.name}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
