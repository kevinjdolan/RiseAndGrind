---
name: photoshop-bg-removal
description: Remove the background from Chad character renders using Photoshop's Select Subject, producing transparent PNGs beside the source jpegs. Use when asked to "remove the background", "apply the photoshop background removal", cut out / matte / knock out a render, make a render transparent, process new jpgs in scratch_data/chad_model_*, or rewrite PNGs that no longer match their jpeg.
---

# Photoshop background removal for Chad renders

The Chad reference renders arrive as opaque `.jpeg` files (dark studio
backdrop). Each one gets a background-removed `.png` sibling with the same
basename, which is what the app assets are built from.

## Quick start

```bash
cd /Users/kevin/code/kevin/RiseAndGrind
.claude/skills/photoshop-bg-removal/remove_bg.sh scratch_data/chad_model_3/chad_relaxed_happy.jpeg
```

Process every jpeg that has no png yet:

```bash
cd scratch_data/chad_model_3
for f in *.jpeg; do [ -f "${f%.jpeg}.png" ] || echo "$f"; done | \
  xargs /Users/kevin/code/kevin/RiseAndGrind/.claude/skills/photoshop-bg-removal/remove_bg.sh
```

The runner writes `<basename>.png` beside each input and then verifies the alpha
channel, warning if a file came out opaque. Photoshop Beta is launched
automatically; it does not need to be open first.

## The procedure

Per file, in Photoshop:

1. Open the jpeg.
2. Convert the locked **Background** layer to a normal layer — a locked
   background cannot carry a mask.
3. **Select Subject** to isolate the figure.
4. Apply that selection as a **Reveal Selection layer mask** (not a pixel
   delete — masking is non-destructive and keeps the soft edge).
5. Save as PNG. The composite honours the mask, so the backdrop becomes alpha.

`ps_remove_bg_and_crop.jsx` implements this. It reads absolute paths from
`/tmp/ps_bg_inputs.txt` and appends results to `/tmp/ps_bg_result.txt`.

## Canvas convention: no cropping by default

**The canvas stays at the source size.** Every existing `<name>.png` matches its
`<name>.jpeg` pixel dimensions, so the subject keeps its position within the
frame and frames stay registered with each other — which matters for animation
pairs like `chad_coin_up` / `chad_coin_down`.

Faces and T-poses *look* cropped only because the subject already fills the
frame; no trim was applied to them.

Pass `--trim` to crop to the subject's bounding box. Do this only when asked —
it breaks registration between frames:

```bash
.claude/skills/photoshop-bg-removal/remove_bg.sh --trim render.jpeg
```

## Auditing pairs

To find jpegs with no png, or pngs that no longer correspond to their jpeg
(e.g. the render was regenerated but the png is stale):

```bash
python3 .claude/skills/photoshop-bg-removal/audit_pairs.py scratch_data/chad_model_3
```

It compares RGB inside the png's opaque region against the jpeg. Correct pairs
score a mean absolute difference of ~0.1–0.2 (jpeg noise); a png from a
different render scores far higher. Rewrite anything reported as `MISMATCH`,
`SIZE_DIFF`, or `NO_PNG` by running it back through `remove_bg.sh`.

## Build-specific gotchas

These cost real time to rediscover, so check here first:

- **`selectSubject` is not a valid action ID** in this build. It throws
  `The command <unknown> is not currently available`. The working ID is
  **`autoCutout`**.
- `removeBackground` also exists and yields an identical matte (verified:
  identical soft-edge pixel counts), but it masks the layer immediately and
  leaves no selection to inspect, so this procedure uses `autoCutout`.
- The mask is created with `charIDToTypeID("Mk  ")` — **two trailing spaces**.
  Same for `"Lyr "`, `"Md  "`, `"Nm  "`, `"At  "`, `"Nw  "`.
- Invoke the script by reading it in AppleScript and passing the **source
  string**. Passing a file reference fails with
  `Can't get POSIX file ... of «script»` / `Can't get file ...`:

  ```bash
  osascript <<'EOF'
  set jsCode to (read (POSIX file "/abs/path/script.jsx") as «class utf8»)
  tell application "Adobe Photoshop (Beta)" to do javascript jsCode
  EOF
  ```

- Use **Photoshop Beta** (`Adobe Photoshop (Beta)`), which is what this
  procedure was developed against. `Adobe Photoshop 2026` is also installed.
- The JSX logs to a file rather than returning values, because `do javascript`
  only surfaces the final expression. Delete `/tmp/ps_bg_result.txt` before each
  run — the script appends.

## Sanity checks

A correct output is `RGBA`, same size as its jpeg, roughly 15–50% opaque for a
full-body figure, with a few thousand partially-transparent edge pixels. Zero
soft-edge pixels means a hard, likely bad matte; zero transparent pixels means
the removal silently did not apply.

Select Subject is per-image machine inference, so inspect the result — composite
over a contrasting colour rather than trusting the alpha histogram alone:

```bash
python3 -c "
from PIL import Image
im = Image.open('out.png').convert('RGBA')
bg = Image.new('RGBA', im.size, (255,0,255,255))
bg.alpha_composite(im); bg.convert('RGB').save('/tmp/check.png')"
```

## Related

- `scripts/generate_chad_pose.py` — generates new Chad poses from an existing
  render via Gemini image models, the usual source of the jpegs processed here.
- `ARTWORK.md` — provenance notes for shipped app artwork.
