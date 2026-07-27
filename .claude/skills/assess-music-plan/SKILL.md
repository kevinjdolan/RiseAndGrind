---
name: assess-music-plan
description: Adversarial, context-free assessment of a Rise & Grind alarm-music plan — per-song rubric (lyrical novelty, wake relevance, literality, musicality rigor, loop structure, vocalist distinctiveness) and whole-set rubric (repeated phrases, tropes, joke collisions, genre/emotion/tempo spread). Use when reviewing a song plan before generation, scoring catalog drafts, or running an independent quality gate.
---

# Assess Music Plan

You are an independent, adversarial reviewer. Judge only the artifact in
front of you. You have no knowledge of the author's intent, effort, or
constraints beyond this document — do not extend goodwill. Your job is to
find what is weak, derivative, repetitive, or structurally unsound BEFORE
expensive audio generation.

## Application context (all you need to know)

Rise & Grind is a satirical hustle-culture iOS alarm app. Its alarm library
is a set of original ~29-second songs that loop seamlessly and indefinitely
via the system alarm framework until the sleeper gets up. Alarms escalate
through five ordered intensity tiers — soothing, relaxing, motivating,
energizing, abrasive — one tier per successive alarm, so a listener may hear
a soothing song at first light and an abrasive one after repeated snoozing.
Playback is phone-speaker mono; production detail must survive a small
speaker. The app's comedic voice is deadpan hustle-culture satire: real songs
that happen to be funny, never novelty joke tracks. Songs are heard half-asleep,
daily, for months — wear-resistance matters. Every song has sung lyrics.

## Per-song criteria (score each 1–5; 3 = publishable, ≤2 = must fix)

1. **Lyrical novelty** — Is the central idea fresh, or a stock joke (alarm
   begging, generic "seize the day", inbox dread cliché)? Would a listener
   quote a line to a friend? Penalize interchangeable lines that could sit in
   any other song.
2. **Wake relevance** — Does the song belong at the moment of waking?
   The connection may be scenic, emotional, ritual, or symbolic — but it must
   exist and fit its tier's position in the escalation.
3. **Literality discipline** — Waking should mostly NOT be stated outright.
   Allusion, extended metaphor, allegory, dramatic scene, symbol are the
   preferred registers. Score 5 when the song never says "wake up" yet is
   unmistakably a waking song; score 1 for on-the-nose alarm narration.
   (A small minority of explicit-command songs is acceptable set-wide.)
4. **Musicality & theory rigor** — Are key/mode, harmony, rhythm, and
   instrumentation specified concretely and idiomatically for the genre? Do
   the stated devices make musical sense together (mode vs. chords, groove vs.
   bpm, instrumentation vs. tradition)? Penalize vague production words
   ("lush pads, driving drums") and theory errors.
5. **Loop-structure coherence** — Check the timestamped structure: integer
   bars, timestamps consistent with bpm, no intro/outro/fade, a named seam
   device, last bars instrumental, energy flat-topped. Verify the arithmetic;
   flag any structure that would audibly "reset" at the seam.
6. **Vocalist distinctiveness** — Is the vocalist castable from the
   description, and distinct from the other 49? Penalize generic descriptors.
7. **Singability & pacing** — Line lengths vs. tempo; can the stated lines be
   sung cleanly inside their allotted bars?

## Whole-set criteria

- **Phrase/image collisions**: list every lyric phrase, image, or rhyme that
  appears in more than one song (exact or near). Zero tolerance for repeated
  signature lines.
- **Joke/premise collisions**: cluster songs whose comic mechanism is the
  same (e.g. two "X as religious liturgy" songs); flag all but the strongest.
- **Metaphor diversity**: catalog each song's central metaphor; flag domains
  used more than once per tier or three times set-wide.
- **Emotional range**: classify each song's emotional reaction to waking
  (tenderness, dread, glee, menace, irony, ceremony, melancholy, defiance…);
  flag tiers dominated by one register.
- **Genre eclecticism**: flag genre-family repeats within a tier and
  distributional sameness across the set; reward regional/tradition breadth.
- **Vocal palette**: flag adjacent songs with similar voice types; the 50
  voices should read like 50 different singers.
- **Tempo/key distribution**: flag bpm clustering and tonality monoculture.
- **Tier fidelity**: does each tier's set feel like its intensity level, and
  does the escalation arc cohere from soothing through abrasive?

## Additional lenses (apply when relevant)

- **Wear-resistance**: will the joke or hook survive 100 mornings, or is it a
  one-listen gag?
- **Half-asleep intelligibility**: are opening lines phonetically clear at
  the stated tempo on a phone speaker?
- **Generatability**: is the spec achievable by current music-generation
  models (no impossible ensembles, contradictory tempo/feel, or 10-part
  counterpoint in 29 s)?
- **Taste**: nothing degrading, no slurs; profanity only where the plan's
  tier policy allows.

## Output format

1. A one-paragraph overall verdict with a set-level score (1–5).
2. Per-tier: table of songs × the seven criteria scores, with one-line
   justification for any score ≤2.
3. Set-level findings: each collision/cluster listed with the involved song
   ids and a concrete prescription (which song to change and in what
   direction).
4. A ranked FIX LIST: every must-fix item ordered by severity, each with a
   specific, actionable instruction. Do not soften; do not pad with praise.
