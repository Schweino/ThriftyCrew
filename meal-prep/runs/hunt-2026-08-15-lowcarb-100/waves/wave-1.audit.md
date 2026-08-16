GO

# Wave 1 audit, round 8 (post-partial-publish re-audit authorizing the hatch retry) - hunt-2026-08-15-lowcarb-100 (2026-08-16, ~16:06)

Auditor: batch audit gate. Scope: the two changes since the 14:55:56 GO (the E2 reanchor re-stamp at
15:52:33 across all 9 specs; the hatch head.description trim at 15:56:57), independent live verification
of the 8 published slugs, and retry-path soundness for hatch-green-chile-chicken-casserole. The wave's
numerics were certified in rounds 5-7 against these same content bytes and were not re-derived.

## The 15:52:33 reanchor re-stamp: VALUE-NEUTRAL, verified on all 9

reanchor-machine-fields.ps1 is key-scoped regex on exactly stat.cost_ps and head.costPerServing with a
parse-verify; nothing else in a spec can move through it. Verified per slug against BOTH the pre-16:04
manifest and the freshly recomputed one (v2-perserving.json, 16:04:06): stat.cost_ps ==
head.costPerServing == manifest everyday_ps == cost_first_run/14, delta 0.00 on all 9. The re-stamped
values equal the certified literals (hatch 4.18 = 58.50/14, stroganoff batch 2.50/everyday 4.28,
cauliflower-mac batch 1.38/everyday 1.77). Tier ordering batch < true-shopping < everyday holds on all 9.

## The 8 published slugs: GENUINELY LIVE AND CORRECT, verified independently

Fetched all 8 public pages at ~16:02: HTTP 200, title present, meta/og description equals the spec's
expanded head.description, Recipe JSON-LD present, and no paid-content leak ("What This Batch Costs"
absent from every anonymous fetch). Spot-checked stroganoff's live Recipe JSON-LD field by field against
the spec: 450 cal / 29 P / 11 C / 31 F, 14 servings, 12 ingredients - exact. All 8 are in
db\published-hashes.json (published by this pipeline, so the retry's P6 dedup guard and hash change-gate
treat them correctly: unchanged specs will skip as UNCHANGED).

## hatch head.description trim: ACCURATE, IN LIMIT, verified

- Raw 305 chars; expanded (cal=530, protein=41) is 292 chars, under Ghost's 300-char custom_excerpt
  limit that caused the 422. Confirmed by recount, not by trusting the dispatch.
- Accuracy against the spec, claim by claim: pulled rotisserie chicken (ingredient 1, 1439 g);
  spiralized zucchini (1029 g); roasted-chile cream sauce with pepper jack (steps 4-6 build the sauce
  from blended chiles, cream, pepper jack; the "roasted" framing matches the certified intro); "no soup
  can and no flour" (true; neither appears anywhere in the build); 14 servings (spec); 530 cal / 41 g
  protein (stat block); "15 grams of carbs or less" (stat.carbs 15, unrounded 14.5). Dropping "real" and
  "and cream cheese" removes emphasis, not truth - nothing in the trimmed text is now false or
  misleading. Voice clean: no em/en dashes, no swearing.
- The other 8 expanded descriptions measured 220-267 chars - none near the limit, so the retry cannot
  trip the same 422 on a collateral republish.

## hatch retry path: SOUND

- Live check at ~16:02: https://www.thriftycrew.com/hatch-green-chile-chicken-casserole/ is a clean 404.
  No half-created post, no <slug>-2 orphan; the retry is a clean create, and hatch is in the wave
  manifest so wave-publish's allow-create file will carry it.
- hatch is absent from published-hashes.json and unstamped in propagate-stamps.json, so it is dirty and
  the chain will rebuild + publish it. Its built card was in fact already rebuilt at 16:03:14 (collateral
  of wave-4's propagate) and now matches the trimmed spec exactly: JSON-LD name, keywords, 530/41/15/33,
  14 servings, all 14 ingredient lines and all 7 steps byte-equal to head.*, description 292 chars (the
  new text). The wave-4 run correctly REFUSED CREATE on hatch (not in its allow-create), which is the
  create guard doing its job.
- All 9 state files read state=waved wave=1 (P3 passes; the 8 live ones re-advance on this retry).
  Ledger row hunt-2026-08-15-lowcarb-100-w1 carries audit/cost-basis/recipes-db stamps; build-cards,
  publish, serveability correctly still owed. This audit file is written after the newest wave-1 spec
  (hatch, 15:56:57), so P1b freshness holds.

## Process findings (for the orchestrator, non-blocking for this retry)

- P-1 DESIGN TRAP, E2 self-invalidation: wave-publish E2 mutates every wave spec mid-publish
  (reanchor-machine-fields re-stamps two fields), so ANY partial failure leaves every spec newer than the
  GO that authorized the run, and P1b then rightly demands a fresh audit before retry. The mutation was
  value-neutral this time and P1b caught it, which is the system working - but a publish path that
  invalidates its own authorization on every run guarantees a re-audit round-trip on every partial
  failure. File: meal-prep\pipeline\wave-publish.ps1 (E2). Fix direction: run the reanchor + freshness
  re-check BEFORE P1b judges (or exempt the two machine fields from freshness by re-anchoring pre-audit),
  decided by the pipeline owner, never by weakening P1b.
- P-2 VALIDATION GAP, Ghost custom_excerpt limit: nothing in the estate validates head.description's
  EXPANDED length against Ghost's 300-char custom_excerpt cap, so the first place a long description
  fails is the final POST with an opaque 422. Cheap fix at either build-v2-spec write-time or as a P5
  check in wave-publish: expand {{tokens}} from stat and refuse > 300. Files:
  meal-prep\pipeline\build-v2-spec* / meal-prep\pipeline\wave-publish.ps1; engine\publish.ps1 line 63 is
  where the expanded $desc becomes custom_excerpt.
- P-3 restated from round 7: the estate is being written during audit windows (wave-3 and wave-4
  published at 16:03-16:04 while this audit ran; hatch's built card changed under this auditor's feet
  mid-read). Nothing wave-1-material moved - all 9 wave-1 spec mtimes re-verified unchanged at the end of
  this audit (8 at 15:52:33, hatch 15:56:57) - but the freeze-during-audit policy from round 7 stands.

## Category verdicts

| Category | Verdict |
|---|---|
| 1. Macros | CLEAN. Untouched since the round 5-7 recompute; live JSON-LD spot-check agrees to the gram. |
| 2. Costs | CLEAN. Reanchor re-stamp verified value-neutral on all 9 against both manifest generations; tiers ordered; literals match the certified figures. |
| 3. Mapping | CLEAN. Untouched since round 7. |
| 4. Protein + rotation | CLEAN. Untouched; recipes-db rows already stamped for the batch. |
| 5. Cards | CLEAN. 8 verified live (title, description, JSON-LD, paywall); hatch's rebuilt card verified byte-consistent with the trimmed spec. |
| 6. Voice + copy | CLEAN. Trimmed description accurate, 292/300 expanded, zero em/en dashes; remaining 8 descriptions 220-267. |
| 7. Gates | INTACT. Nothing weakened; P1b, the create guard, and the hash change-gate all observed doing their jobs during this window. |

GO. The 8 published slugs are live and correct, the reanchor re-stamp changed no value, hatch's trimmed
description is accurate and inside the Ghost limit, and its retry path (clean 404, dirty spec, fresh
card, allow-create coverage, waved state, stamped ledger) is sound. Retry wave 1 to publish hatch.
