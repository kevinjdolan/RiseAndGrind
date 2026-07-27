---
name: compose-looping-alarm-songs
description: Compose plans for 29-second seamlessly looping alarm songs — loop-first structure with timestamped moments, bar-math tempo selection, lyric craft for wake-up satire, vocalist and instrumentation specification, and set-level variety management. Use when authoring or extending a Rise & Grind music catalog plan, writing new alarm songs, or defining per-song structure before generation.
---

# Compose Looping Alarm Songs

Write each song as a LOOP FIRST and a song second. The 29-second clip repeats
indefinitely at wake time; the seam is part of the composition, not a
post-production accident.

## Plan entry schema (YAML, one per song)

```yaml
- id: soothing_001            # tier_NNN
  title: "..."                # 1–4 words, fresh vocabulary
  artist: "..."               # fictional act, plausible for genre; NEVER sent to generators
  genre: "..."                # specific subgenre label
  vocalist: "..."             # independent field: gender + timbre + delivery, concrete and distinctive
  bpm: 99                     # from the bar-math table below
  meter: "4/4"
  bars: 12                    # whole bars filling ~29 s at this bpm
  key: "F Lydian"             # key/mode; name modulations if any
  instrumentation: "..."      # named instruments and production treatments, 15–35 words
  rhythm: "..."               # groove description: drum pattern feel, syncopation, swing %, accent scheme
  structure:                  # timestamped moments; times in seconds from loop start
    - "0.0  Downbeat: groove enters at full energy (no intro build)"
    - "2.4  Vocal line 1 enters on a pickup"
    - "..."
    - "26.5 Turnaround: harmonic/rhythmic device that resolves INTO 0.0"
  loopSeam: "..."             # one sentence: exactly how bar 12 beat 4 hands off to bar 1 beat 1
  lyrics:
    - "..."                   # each line 4–9 words, singable at bpm
  premise: "..."              # the one comic/emotional idea, one sentence
```

## Loop-first structure rules

1. **No intro, no outro.** The clip starts at full arrangement on a downbeat
   and the final bar is a turnaround that resolves into that downbeat. Fades,
   ritardandos, final cadences, cymbal-swell endings are all defects.
2. **Whole-bar duration.** The loop must be an integer number of bars. Choose
   bpm from the bar-math table so whole bars fill 29.000 s within ±0.6 %
   (mastering micro-stretches the rest; run `python3 scripts/loop_bar_math.py`
   to print valid options for any meter).

   4/4 fits: 66.2=8 bars · 74.5=9 · 82.8=10 · 91.0=11 · 99.3=12 · 107.6=13 ·
   115.9=14 · 124.1=15 · 132.4=16 · 140.7=17 · 149.0=18 · 157.2=19 · 165.5=20 ·
   182.1=22 · 198.6=24 · 215.0=26. (3/4 and 6/8: bpm = bars × 180 ÷ 29.)
3. **Seam devices — pick one deliberately and name it in `loopSeam`:**
   circular chord progression that never cadences (e.g. i–VI–III–VII);
   dominant-pickup turnaround landing on the tonic downbeat; drone/pedal that
   never moves; continuous ostinato or drum pattern crossing the seam;
   melodic phrase whose last note is the leading tone into the first note.
4. **Keep the last 2 bars vocal-free** (instrumental turnaround) so the loop
   restart never clips a sung word.
5. **Timestamps must be consistent** with bpm and bars: a moment at bar 9 of a
   99.3 bpm 4/4 song is at (9−1)×240/99.3 ≈ 19.3 s. Check the arithmetic.
6. **Energy is flat-topped, not an arc.** Verses may breathe, but the loop
   must re-enter at the same intensity it left; no built-then-dropped climax.

## Lyric craft

- Wake-up relevance through ALLUSION more than statement: symbolism, extended
  metaphor, in-scene drama, absurd ritual. Explicit "wake up now" lines are a
  budget item: at most 2 songs per 10 use imperative wake commands.
- One comic/emotional premise per song, stated in `premise`. Deadpan beats
  wacky; specificity beats abstraction.
- Lines 4–9 words, no forced rhyme, singable at tempo (fast tiers → shorter
  lines, front-stressed words).
- Language: as the catalog version specifies (v6: English only).
- Profanity: follow the catalog version's tier policy; never degrading or
  sexual terms.
- Vocalist field must be distinctive enough to CAST from: "smoky contralto,
  behind-the-beat, cracks on held notes" — never "good female singer".

## Set-level variety (apply across the whole plan)

Maintain a running ledger while composing; before finalizing, verify:
- No repeated titles, artists, central metaphors, signature images, or jokes.
- No two songs share an opening lyric word within a tier.
- Genre spread: no genre family twice within a tier; regional traditions
  encouraged even with English lyrics.
- Emotional register spread per tier: rotate among tenderness, irony, menace,
  glee, melancholy, absurd ceremony, sincere joy — the reaction to waking
  should differ song to song.
- BPM/key spread: avoid clustering; use minor AND modal AND major tonalities.
- Motif budget per 10 songs: coffee ≤1, inbox/email ≤1, meetings ≤1,
  calendar ≤1, snooze ≤1, sunrise-personification ≤1.

## Process

1. Decide tier voicing and pick 10 genre seeds per tier (all distinct).
2. Fill the schema for every song, seam device first, lyrics last.
3. Self-audit against the variety ledger and rule list above.
4. Validate mechanically where possible (bar math, budgets, uniqueness).
5. Hand the plan to `assess-music-plan` for adversarial review before any
   audio generation.
