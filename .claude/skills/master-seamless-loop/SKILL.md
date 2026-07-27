---
name: master-seamless-loop
description: Master generated song audio into exact 29-second beat-maintained seamless loop CAFs — tempo verification, whole-bar loop cuts, bar-aligned seam crossfades, micro time-stretch to exact duration, phone-speaker chain, and validation. Use when mastering alarm loops, fixing audible loop seams or beat hiccups at the wrap point, or converting Lyria/ElevenLabs output for the app.
---

# Master Seamless Loop

The seam is musical, not just amplitudinal: a loop clicks when the waveform
is discontinuous, but it *stumbles* when the beat phase is discontinuous.
Fix both, in this order.

## Why the old chain stumbled

The v4 chain cut every song at exactly 29.000 s regardless of tempo, then
crossfaded the tail into the head. Unless 29 s happens to be a whole number
of bars, the cut lands mid-bar, so the crossfade blends two different beat
phases — audible as a skipped or doubled beat every 29 s even though the
waveform itself is smooth.

## Procedure

1. **Compose for the loop** (upstream): every plan entry carries `bpm`,
   `meter`, `bars` chosen with `scripts/loop_bar_math.py` so whole bars fill
   29 s within ±0.6 %. Generation prompts must demand: start on the downbeat
   at full arrangement, no intro/outro/fade, return to the opening groove.
2. **Master each track** with `scripts/master_loop_v6.py IN OUT.caf
   --bpm B --meter M --bars N`, which:
   - estimates the source's actual tempo near the planned BPM (onset-energy
     autocorrelation; low-confidence estimates — beatless ambient — fall back
     to the planned BPM, where bar phase is irrelevant anyway);
   - cuts the loop at the whole-bar boundary `bars × beats × 60/bpm`;
   - bridges the seam with a ≤1-beat equal-power crossfade of the bar AFTER
     the loop point into the loop head — two downbeats blended in phase;
   - micro time-stretches (pitch-preserving `atempo`) by `29.000/L`, capped
     at ±2 % (planned tempos need ≤0.6 %);
   - applies the phone chain (90 Hz highpass, 10 kHz lowpass, presence lift,
     compression, limiting) and encodes mono 22.05 kHz IMA4 CAF;
   - validates exact duration (639 450 samples), codec, and the 410 000-byte
     app budget, and reports usedBpm/stretch/confidence.
3. **Audition the seam specifically** — build seam-only previews (last 5 s +
   first 5 s) with the `preview-music-samples` skill; a correct loop sounds
   like bar 12 walking into bar 1 of the same performance.

## Rules

- Never cut at a fixed wall-clock time; always at a whole-bar boundary.
- Never stretch more than 2 %; prefer regenerating over audible warping.
- Keep the crossfade at or under one beat; long crossfades smear downbeats.
- Preserve the untouched source master; masters are the only path back.
- Verify every delivered asset with the same validators the app build uses
  (`validate_app_audio`); a file merely existing is not enough.
- Sources whose final bars are a fade/outro cannot be rescued by mastering —
  regenerate with stronger loop-authoring prompt language instead.
