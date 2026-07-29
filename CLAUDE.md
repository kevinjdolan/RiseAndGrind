# Rise & Grind — working notes for Claude

Satirical hustle-culture iOS alarm app. Alarms escalate through five ordered
intensity tiers (soothing → relaxing → motivating → energizing → abrasive);
each built-in song is an original ~29 s seamless loop played by AlarmKit.

## Music pipeline (v6 procedure)

Catalog work happens plan-first, with an adversarial review before any audio
is generated. The five project skills in `.claude/skills/` define the
procedure — load the relevant one before doing the work:

1. `compose-looping-alarm-songs` — author plans: loop-first structure with
   timestamped moments, bar-math tempos (`scripts/loop_bar_math.py`), lyric
   and variety rules.
2. `assess-music-plan` — context-free adversarial review. Run it in a fresh
   agent session (max reasoning) whose only inputs are that skill file and
   the plan; it must not see the authoring conversation.
3. `revise-music-plan` — respond to an assessment in a fresh agent session:
   triage, rewrite, rebalance, change log.
4. `master-seamless-loop` — beat-maintained mastering to exact 29 s IMA4 CAF
   (`scripts/master_loop_v6.py`); never cut at wall-clock time.
5. `preview-music-samples` — audition tables: full-loop ×2 and seam-only
   clips (`scripts/build_music_previews.py`) under gitignored `tmp/`.

Catalog versions live in `scratch_data/` (gitignored): `music_v6/` is the
current effort; v4 is installed in the app, v5 was a lyrics-only revision.
Generation scripts for the installed library: `generate_music_library_v4.py`
(Lyria; prompts must NEVER include artist names — Google's input filter
rejects person-like names), `install_music_library_v4.py` (atomic swap +
`--check`), `generate_elevenlabs_music_samples.py`.

Constraints that bite:
- App audio: mono 22.05 kHz IMA4 CAF, exactly 29.000 s (639 450 samples),
  ≤410 000 bytes each; manifest schema is validated hard in
  `RiseAndGrind/Services/SoundLibrary.swift` (schemaVersion/trackCount/
  tierCounts) — update it together with any catalog size change, plus
  `Models.swift` defaultSelectedSoundIDs and `SchedulePlannerTests`.
- API keys load at runtime from `/Users/kevin/code/kevin/academic-slop/omni/.env`
  (`GEMINI_API_KEY`, `ELEVEN_LABS_KEY`); never print or commit them.
- After adding/removing bundled files run `xcodegen generate`; gate every
  library change with `./scripts/verify_project.sh`.
- The app ranks songs by a vulgarity score (`SoundVulgarity`); profanity
  policy is tiered — soothing/relaxing clean, motivating/energizing at most
  mild, abrasive carries the deliberate clean-to-filthy gradient. Never use
  degrading/sexual terms or slurs anywhere.

## General

- Tooling: prefer `rg`; Python scripts are stdlib-only (no pip installs into
  system Python — use a scratchpad venv when numpy etc. is genuinely needed).
- Tests: `swift test` (Core package); strict `swift-format lint` gates
  `verify_project.sh`.
- Versioning: bump the patch component of `MARKETING_VERSION` for essentially
  every shipped app change. Bump the minor component (and reset patch to zero)
  for a materially larger feature or behavior set. Increment
  `CURRENT_PROJECT_VERSION` for every device build intended for distribution
  or hands-on testing.
- Bundled videos: always optimize for file size unless told otherwise — these
  ship in the app binary, not streamed. Match the existing
  `RiseAndGrind/Resources/CalibrationInstructions/*.mp4` convention: HEVC
  (`libx265`, Main profile, `-tag:v hvc1` so AVPlayer reads it cleanly),
  square crop/scale to 720x720, mono AAC ~64 kbps, two-pass at ~450 kbps
  video (`-maxrate 500k -bufsize 900k`), `-movflags +faststart`. That combo
  holds ~30-45 s clips to a few MB with negligible visible quality loss.
