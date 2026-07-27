---
name: preview-music-samples
description: Build convenient listening previews for generated alarm loops — per-song files playing the loop twice, seam-only clips (last 5 s + first 5 s), and a markdown table of links grouped by tier with one column pair per provider, all in a temp directory. Use when the user wants to audition generated songs, compare providers, or check loop seams.
---

# Preview Music Samples

Give the user two listening modes per song and provider:
- **`_x2`** — the loop played twice back-to-back; the repeat boundary is
  exactly the seam the alarm will hit every 29 s.
- **`_seam`** — only the last 5 s followed by the first 5 s; isolates the
  wrap point for fast seam judgment.

## Procedure

1. Collect or write a manifest JSON: a list of entries with `id`,
   `displayName`, `intensityTier`, and either `loops: {provider: path}`
   (multi-provider) or `provider` + `loop` (single), paths relative to the
   repo root. Pipeline sample manifests (e.g.
   `scratch_data/V5Samples/samples_manifest.json`) already fit.
2. Run:

   ```sh
   python3 scripts/build_music_previews.py MANIFEST.json --out tmp/<name>
   ```

   Output lands under the repo's gitignored `tmp/`: per-tier directories of
   `<Song>_<provider>_x2.m4a` and `<Song>_<provider>_seam.m4a`, plus
   `index.md` — a table per tier with one row per song and a
   [play]/[seam] column pair per provider.
3. Reply to the user with clickable links: link `index.md`, the tier
   directories, and call out notable tracks. When the user asks for a table
   inline, render index.md's table in chat with links rewritten relative to
   the repo root.

## Rules

- Always place previews under the repo's `tmp/` (gitignored); never in
  `Resources/` and never committed.
- Decode CAF sources with `afconvert` (ffmpeg cannot demux afconvert CAFs);
  encode previews as 96 kbps mono AAC `.m4a` — Finder/QuickTime-friendly.
- Keep names Finder-sortable: `NN_Title_provider_kind.m4a` ordering pairs
  adjacently when a numbered order matters.
- A/B fairness: both providers' previews must come from identically mastered
  loops (same chain, same loudness policy), or note the difference.
