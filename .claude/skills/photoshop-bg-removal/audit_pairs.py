#!/usr/bin/env python3
"""Audit <name>.jpeg / <name>.png pairs in a render directory.

For each jpeg, reports whether its png sibling is really derived from it, by
comparing RGB inside the png's opaque (subject) region against the jpeg. A png
built from a different render shows a large difference; a correctly processed
one differs only by jpeg compression noise (well under 1/255 in practice).

Usage:
    python3 audit_pairs.py [DIR]

Statuses:
    NO_PNG      jpeg has no png sibling yet -> needs background removal
    SIZE_DIFF   png canvas differs from the jpeg (e.g. it was trimmed)
    MISMATCH    png content does not correspond to the jpeg -> rewrite it
    MATCH       png is the processed version of this jpeg
"""

from __future__ import annotations

import glob
import os
import sys

from PIL import Image, ImageChops, ImageStat

# Mean abs RGB difference inside the subject, in 0-255 units. Correct pairs
# measure ~0.1-0.2 (jpeg noise); a different render measures orders of
# magnitude higher.
MATCH_THRESHOLD = 6.0


def opaque_fraction(mask: Image.Image) -> float:
    hist = mask.histogram()
    total = mask.size[0] * mask.size[1]
    return sum(i * c for i, c in enumerate(hist)) / 255 / total


def audit(directory: str) -> int:
    mismatches = 0
    jpegs = sorted(glob.glob(os.path.join(directory, "*.jpeg")))
    jpegs += sorted(glob.glob(os.path.join(directory, "*.jpg")))
    if not jpegs:
        print(f"no jpegs found in {directory}")
        return 0

    for jpeg in sorted(jpegs):
        base = os.path.splitext(jpeg)[0]
        name = os.path.basename(base)
        png = base + ".png"

        if not os.path.exists(png):
            print(f"{name:26s} NO_PNG     jpeg={Image.open(jpeg).size}")
            mismatches += 1
            continue

        ji = Image.open(jpeg).convert("RGB")
        pi = Image.open(png).convert("RGBA")

        if ji.size != pi.size:
            print(f"{name:26s} SIZE_DIFF  jpeg={ji.size} png={pi.size}")
            mismatches += 1
            continue

        mask = pi.getchannel("A").point(lambda v: 255 if v > 128 else 0)
        frac = opaque_fraction(mask)
        diff = ImageChops.difference(pi.convert("RGB"), ji).convert("L")
        masked = Image.composite(diff, Image.new("L", diff.size, 0), mask)
        mean = ImageStat.Stat(masked).mean[0] / max(frac, 1e-6)

        status = "MATCH    " if mean < MATCH_THRESHOLD else "MISMATCH "
        if mean >= MATCH_THRESHOLD:
            mismatches += 1
        print(f"{name:26s} {status}  opaque={frac:.3f} mean_abs_diff={mean:.2f}")

    return mismatches


if __name__ == "__main__":
    target = sys.argv[1] if len(sys.argv) > 1 else "."
    count = audit(target)
    print()
    print(f"{count} file(s) need attention" if count else "all pairs match")
