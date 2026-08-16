GO

# Wave 1 audit, round 7 (scoped re-audit of the three B5/ruling-#18 slugs) - hunt-2026-08-15-lowcarb-100 (2026-08-16, ~14:55)

Auditor: batch audit gate. Scope per the prior round's own prescription: cert freshness on
low-carb-ground-beef-stroganoff-skillet, baked-cauliflower-mac-smoked-sausage,
hatch-green-chile-chicken-casserole, plus the hatch carb-copy prose field, plus the estate-level
audit-store-integrity.ps1 alias change. The wave's numerics (macros, costs, mapping, protein, cards,
gates) were fully verified against these same bytes in rounds 5-6 and were not re-derived here; the
only reader-facing change since is the hatch prose fix verified below.

## B1 (stale certs): RESOLVED, verified on mtimes and content

- Freshness sweep across ALL 9 manifest slugs at 14:54: every cert postdates its spec. The three
  scoped: specs 14:40:00, certs 14:45:55 / 14:45:55 / 14:46:26.
- Cert content is re-derived, not inherited: each cert states an independent food-DB recompute on
  current bytes (stroganoff 450.0/28.9/11.3/31.1 vs stat 450/29/11/31; cauliflower-mac
  628.3/25.0/16.2/50.9 vs 628/25/16/51; hatch 529.7/40.7/14.5/32.9 vs 530/41/15/33) - figures
  identical to round 6's independent recompute of the 13:58 bytes, confirming no numeric drift.
  Cost literals in the certs match costed.json line for line (stroganoff Sour Cream util 2.91,
  batch_ps 2.50; cauliflower-mac batch_ps 1.38; hatch batch_ps 2.59, cost_ps 4.18 = 58.50/14).
- Verdict pass, both anchors (extraction + live page) on all three.

## B2 (hatch carb copy): RESOLVED, verified on bytes

stat.carbs 15 (14.5 unrounded); intro_html and head.description both read "15 grams of carbs or
less" (2 occurrences); zero instances of "under N grams" remain anywhere in the spec. The claim is
true beside the unrounded 14.5.

## Writer_note corrections: present

Stroganoff carries 2 dated RESOLVED 2026-08-16 annotations (the false all-five-unwired/floor claim -
all five bids verified live in db\ingredients.json, brandy carries a real cost line); cauliflower-mac
2 (the 642/8-headroom BAND figures, now 628/22 matching stat); hatch 2 RESOLVED + 1 NOTE (543.8 ->
530). Original text preserved. Voice: zero em/en dashes, zero swearing in all three specs.

## N-A / N-C: fixed

qa\creamy-tuscan-chicken-skillet.json parses (verdict pass; cert 14:21 still newer than spec 13:44).
food-macros-db.json Spinach note now records the fresh `spinach` bid with a dated correction;
macros untouched.

## audit-store-integrity.ps1 alias change: A TIGHTENING-SHAPED CORRECTION, NOT A WEAKENING - proven by A/B

Ran the pristine HEAD version and the fixed version against the SAME current data:
- HEAD: 8 HARD (all MISSING-SIDE for the 7 adjudicated aliases), 13 WARN, exit 1.
- Fixed: 0 HARD, 13 WARN, exit 0.
- The WARN sets are byte-identical (13 BASE-DRIFT rows). The fix removed exactly the 8 false HARDs
  and nothing else. Every one of those 8 lines is genuinely priced: costed.json books real board
  bases (e.g. Smoked Sausage via kielbasa/walmart util 7.01; Sour Cream via sour-cream/walmart
  util 2.91) because the cost engine has resolved aliases since f60ede7f, as does
  engine\audit-db-agreement.ps1. The guard was the laggard; it now mirrors actual resolution.
- Alias data audited: 10 aliases on 302 rows, zero collisions with item names, zero duplicate
  aliases, so the first-wins indexing cannot shadow a real row today.
- Self-test 20/20 including the clean twin (an unmapped name still fails to resolve) and a new
  parse-sanity floor (index < 200 names refuses hard). Detection of genuine dropped lines is intact.
- Discrepancy with the dispatch, non-material: the dispatch said "the 19 WARNs intact"; the real
  count is 13 both before and after. The substance (WARN set unchanged) is proven above; the number
  19 appears to be a miscount (possibly from the self-test fixture's "19 unmapped names" wording).

## Non-blocking notes

- N-D restated: the estate root still carries broad uncommitted changes (14 recipe specs including
  live pages, the guard, engine files) by Brad's explicit choice while a concurrent session edits the
  publish chain. wave-publish names foreign dirty by design and propagate carries it; the live-page
  republish still needs its own QA pass per round 6's N-K, and an untimely crash loses real work.
  Commit remains the right next act after publish.
- Round 6's N-G (audit-cost-line-coverage -Slugs comma vacuity), N-H (known-wrong frozen broccoli
  row still cheapest on the feed tile), N-J (nested-paren display nit) remain open and non-blocking.
- Process finding stands: three consecutive rounds found mid-audit estate writes. This round the
  window stayed still (verified by an end-of-audit mtime sweep at 14:54), but freeze estate-writing
  sessions during audit windows as policy.

## Category verdicts

| Category | Verdict |
|---|---|
| 1. Macros | CLEAN. Stats unchanged since round 6's exact recompute; certs re-derived them independently on current bytes and agree to the decimal. |
| 2. Costs | CLEAN. Unchanged since round 6 (penny-exact); alias-named lines verified priced on real board bases. |
| 3. Mapping | CLEAN. Unchanged; alias table audited collision-free, same-concept per the recorded adjudications. |
| 4. Protein + rotation | CLEAN. Untouched this round. |
| 5. Cards | CLEAN for this stage. Cards build at publish through the gates; no new visual surface, no new 375px obligation. |
| 6. Voice + copy | CLEAN. Hatch copy now truthful against the unrounded figure; no em/en dashes, no swearing in the three touched specs. |
| 7. Gates | INTACT and one gate REPAIRED: store-integrity's alias fix is a false-positive correction proven by A/B with an identical WARN set, self-tests 20/20, plus a new hard parse-sanity floor. Nothing weakened. |

GO. All 9 certs fresh in mtime and content, both prior blockers closed on bytes, the guard repair is
sound, and nothing moved during the audit window.
