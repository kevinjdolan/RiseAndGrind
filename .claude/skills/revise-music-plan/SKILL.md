---
name: revise-music-plan
description: Respond to an adversarial assessment of a Rise & Grind music plan and produce an improved version — triage findings by severity, rewrite versus polish decisions, set-level rebalancing, regression protection for praised songs, and a verification checklist. Use when revising a song plan after an assess-music-plan review, or whenever incorporating structured critique into a catalog draft.
---

# Revise Music Plan

Turn an assessment into a strictly better plan. The assessment is advisory
input, not a diff to apply blindly: you own the final artistic call, but
every must-fix finding needs either a fix or a stated reason it is wrong.

## Procedure

1. **Read in this order**: the composition rules
   (`.claude/skills/compose-looping-alarm-songs/SKILL.md`), the current plan,
   then the assessment. Internalize the rules before touching songs.
2. **Triage the FIX LIST**:
   - *Structural defects* (bar math, seam devices, timestamp arithmetic,
     intro/outro violations) — fix mechanically, always.
   - *Collisions* (phrases, premises, metaphors, voices) — keep the strongest
     member of each cluster untouched; move the others to genuinely new
     territory, not adjacent territory.
   - *Low scores* (≤2 on any per-song criterion) — rewrite the failing
     dimension; a 1–2 on novelty or literality usually means a NEW premise,
     not edited lines.
   - *Disagreements* — you may reject a finding; record it in the change log
     with one sentence of justification. Reject sparingly.
3. **Rewrite discipline**:
   - Preserve identity fields (id, tier position) always; preserve title,
     artist, genre, vocalist, bpm unless a finding names them.
   - A rewritten song must satisfy every composition rule (seam device named,
     timestamps recomputed, lyric budgets) — re-derive, don't patch.
   - Guard against regression: do not edit songs the assessment scored well
     except where a set-level finding requires it; never reuse a phrase,
     metaphor, or joke that exists anywhere else in the plan, including in
     songs you just rewrote.
4. **Set-level rebalancing**: after per-song fixes, recheck distributions the
   assessment flagged (emotional registers, bpm/key clustering, genre
   repeats, motif budgets). Adjust the WEAKEST songs to rebalance, not the
   strongest.
5. **Self-verify before emitting** (the checklist):
   - every must-fix finding addressed or explicitly rejected;
   - bar math valid for every song (bars × beats × 60/bpm ≈ 29.0 ± 0.6 %);
   - structure timestamps consistent with bpm/bars; final bars vocal-free;
   - no phrase/image/premise duplicated anywhere in the new plan;
   - schema complete for every song; language policy honored;
   - variety ledgers (metaphor, opener words, motif budgets) pass.
6. **Emit**:
   - the full revised plan in the identical schema (every song present, even
     unchanged ones);
   - a change log: per song touched — what changed and which finding drove
     it; plus the list of rejected findings with reasons.
