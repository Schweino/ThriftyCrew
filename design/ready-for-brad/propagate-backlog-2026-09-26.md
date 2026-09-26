# Propagate backlog and the Meal Plan Builder feed: a plan to approve (2026-09-26)

Source: residual (d) of triage item 2026-09-26-177835 (`grocery/triage-plans/plan-2026-09-26-2.json`). Nothing
here has been run live. No propagate, no publish, no Ghost call, no feed commit. Every number below was measured
on this date in a worktree at origin/main `052a7e864`, and the main checkout had no change to any spec or to
`meal-prep/pipeline/propagate-stamps.json`, so it sees the same dirty set.

## Knowledge consulted

- `.claude/rules/meal-prep.md`: propagate publishes the whole dirty set, dirty is spec-hash against stamps, and a
  hand run refuses (exit 2) when a dirty spec is not named in `-SlugsFile` unless `-AllowCatalogue`.
- `.claude/rules/meal-prep.md`, Brad 2026-09-25: a live recipe that cannot be fully costed is taken down, so held
  and unpriced slugs must not be republished.
- memory `spec-mtime-is-not-evidence-of-a-recost`: dirtiness was judged by hash and field diff, never by mtime.
- knowledge-search `--estate "propagate held stamp planner feed"`: nothing applicable.

## 1. The count is 70, not 95

`propagate-recipes.ps1 -DryRun -Full` (exit 0):

    propagate: 70 dirty spec(s) of 587
    propagate scope: 70 of 70 dirty spec(s) were not named by the caller (bar 0) - a live run REFUSES without -AllowCatalogue

70 of 587 specs (11.9%) are dirty. The "95" in the residual does not reproduce; it was probably counted before
the 09-26 integration commits or by a different test. The stamps were last written 2026-09-19 by the catalogue
republish (`3371c6df5`), so the backlog runs from 09-19, not 09-02.

## 2. Why each is dirty

Method: for each dirty slug, the spec at `3371c6df5` against the spec at HEAD, with the four masked fields
removed (`cost_ps`, `costPerServing`, `fact_claims`, `price_claims`), listing the top-level keys that differ.
One row per slug is in the classifier output; totals below are derived from it.

| Bucket (top-level keys that changed) | Slugs |
|---|---|
| `scaler` | 18 |
| `shop_smart` | 17 |
| `intro_html` | 9 |
| `head` | 5 |
| `cost_closing_html` | 4 |
| `portion_html` | 3 |
| two keys (`head`+`shop_smart` 2, `intro_html`+`shop_smart` 2, and 1 each of five other pairs) | 9 |
| `make_it` | 1 |
| never stamped (no stamp entry at all) | 4 |
| **total** | **70** |

0 of 70 are stale-stamp-only: every stamped dirty slug has a real field change since 09-19. All are
reader-visible sections, so a republish changes page bytes.

Where the changes came from (newest commit touching each of the 63 proposed slugs): 36 from `ba13faba0` (09-22
money lane, board and feed ship), 7 from `19aa534c8` (09-26 177835 rebids, the seven released today), 5 from
`3feb147bf` (09-26 integration rebuild), 5 from the 09-23 daily, 3 from `66ed2335a` and 2 from `fb2e5eb9b` (09-19
I143 claim-word rewrites), 3 from `39738ce0c` (09-22 shallots/chorizo/zest recost), 1 from the 09-24 daily, 1 from
`e6e22da17` (09-21 live prices stage 2).

The 7 released today (`beef-chow-mein-noodles`, `beijing-zha-jiang-mian-pork-noodles`,
`five-spice-turkey-noodle-bowls`, `ground-turkey-lo-mein`, `spicy-pork-noodles`, `turkey-zha-jiang-mian`,
`blackened-chicken-with-mango-salsa`) are all 7 in the `scaler` bucket. They were republished today by a direct
publish, which never writes propagate stamps, so they stay dirty. Publish's content hash should skip them with
one GET each.

## 3. Excluded: 7 of 70

| Slug | Why excluded |
|---|---|
| `andong-jjimdak-braised-chicken` | HELD (hold-recipe 2026-09-23, dangmyeon not on any Omaha cell); costed.json: 1 unpriced, 1 uncarried line |
| `korean-beef-japchae-noodle-bowls` | HELD, same dangmyeon cause; 1 unpriced, 1 uncarried |
| `korean-turkey-japchae` | HELD, same dangmyeon cause; 1 unpriced, 1 uncarried |
| `beef-protein-pasta` | never stamped and absent from `published-hashes.json`; live status not provable without Ghost |
| `chicken-marinara-pasta` | same (09-22 legacy rebuild, commit `fd9c443cc`) |
| `free-chicken-alfredo` | same; it IS in `free-rotation.json`, so it is very likely live, but not proven here |
| `shredded-bbq-chicken-sammies` | same |

The four legacy rebuilds are excluded for proof, not because they are wrong. If they are live, they need this
republish more than anything else (their rebuild fixed a paid/free schema defect and a "72 oz dry" sauce line).
If they are not live, publish refuses them as `REFUSED CREATE` and they stay dirty, which is safe. **Ruling asked
(R1): add the four to the slugs file?** A one-minute check in Ghost admin answers it.

The proposed slugs file is `design/ready-for-brad/propagate-backlog-2026-09-26-slugs.txt`: 63 slugs, one per line.

## 4. Why "just run propagate with the slugs file" is not safe today

Three defects found while planning. Each is in the source, not inferred.

1. **`-SlugsFile` authorises, it does not scope.** propagate builds and publishes `$dirty`, the whole set
   (`propagate-recipes.ps1` lines 455 and 491-492). Naming 63 leaves 7 unnamed, so the run is refused; the only
   ways past are `-MaxUnnamed 7` or `-AllowCatalogue`, and both then carry all 70, the 3 held ones included.
2. **A held slug refused by publish gets STAMPED clean.** `engine/publish.ps1` line 390 builds the unstampable
   list from failed, refused-create, staged and rollout-held only. `refusedHeld` and `refusedCarriage` are not in
   it. So the 3 held recipes would be refused (good) and then marked propagated (bad): when dangmyeon is priced
   and they are released, propagate will think they are clean and never republish them.
3. **The gen-planner-data stage exits 1 today, so any live propagate run throws.** `gen-planner-data.ps1` exits 1
   whenever it drops a recipe with no `v2-perserving` row. Today it drops 9, all held or unpriced (the three
   above plus `ethiopian-doro-wat-chicken-bowls`, `ethiopian-minchet-abish-berbere-beef-bowls`,
   `harissa-chicken-rice-bowls`, `pakistani-chapli-kebab-rice-bowls`, `persian-fesenjan-chicken-bowls`,
   `tunisian-harissa-coconut-beef-meatballs`). propagate's `Invoke-Stage` throws on any non-zero exit, so the
   chain stops at stage 3 and no card builds. Dropping a held recipe is correct; failing on it is the defect.

## 5. What regenerating the Meal Plan Builder feed changes (dry run, restored after)

Ran `meal-prep/gen-planner-data.ps1` in the worktree (exit 1, the drop signal above), diffed
`public/planner-data.json` against HEAD per recipe, then restored both output files with `git checkout`.

- Rows: 583 at HEAD, 578 regenerated. 4 added (the four legacy rebuilds), 9 removed (the 9 held/unpriced above).
- **The live feed is a week stale, not just missing the 7.** It was last committed 2026-09-19 (`3371c6df5`).
  556 of the 574 shared rows change `cps` (cost per serving): 435 up, 121 down, median +$0.10, range -$0.33 to
  +$1.21. 18 rows also change their ingredient lines.
- **The live feed still lists 9 held recipes** in the Meal Plan Builder, including 3 held since 09-19.
- The 7 released today, `cps` HEAD to regenerated: beef-chow-mein-noodles 3.83 to 4.21,
  beijing-zha-jiang-mian 2.70 to 3.09, five-spice-turkey-noodle-bowls 3.92 to 4.58, ground-turkey-lo-mein 4.96
  to 5.18, spicy-pork-noodles 2.97 to 3.93, turkey-zha-jiang-mian 3.20 to 3.74, blackened-chicken 3.72 to 3.89.
  Ingredient line counts unchanged.
- 7,729 of 7,729 ingredient lines feed-priced; 578 of 587 recipes shown.

So the planner regeneration is worth doing on its own and first: it is the one step that fixes a live
understatement today (435 tiles too cheap) and removes held recipes from a paid tool. Committing
`public/planner-data.json` is the deploy.

## 6. Commands to approve

**Recommended (long-term): fix the three defects, then run propagate as designed.** One code change with
fixtures, through the gate:
- publish.ps1: add `$refusedHeld` and `$refusedCarriage` to `$unstampable` (MUST FIRE: a held slug stays dirty).
- gen-planner-data.ps1: a dropped slug that is in `held-recipes.json` or has unpriced lines is reported and does
  not fail; any other drop still exits 1 (MUST FIRE and CLEAN TWIN).
- propagate: build and publish `$dirty` intersected with the named set when `-SlugsFile` is given, leaving the
  rest dirty and unstamped. This reverses nothing in the 08-15 decision for the unnamed, full-catalogue road.

Then, from a clean checkout of main, after `sync-recipesdb-cost` per the recost aftercare rule:

    powershell -NoProfile -File meal-prep\pipeline\sync-recipesdb-cost.ps1 -Apply
    powershell -NoProfile -File meal-prep\pipeline\propagate-recipes.ps1 -DryRun -SlugsFile design\ready-for-brad\propagate-backlog-2026-09-26-slugs.txt
    powershell -NoProfile -File meal-prep\pipeline\propagate-recipes.ps1 -SlugsFile design\ready-for-brad\propagate-backlog-2026-09-26-slugs.txt

and commit the stamps, `recipes-db.json`, `planner-data.js`, `public/planner-data.json` and the journal, landed
with `ops\push-main.ps1`.

**Interim (if the planner cannot wait for the fix): the feed alone, today.**

    powershell -NoProfile -File meal-prep\gen-planner-data.ps1
    # expect exit 1 naming exactly the 9 held/unpriced slugs above; any other name means stop
    git add -- meal-prep/planner-data.js public/planner-data.json
    git commit -F <msgfile> -- meal-prep/planner-data.js public/planner-data.json
    powershell -NoProfile -File ops\push-main.ps1

**Not recommended:** `-MaxUnnamed 7` or `-AllowCatalogue` today. Both stamp the 3 held slugs clean (defect 2)
and both die at stage 3 anyway (defect 3).

## 7. Risk

- 63 live paid pages get a Ghost PUT. The content-hash gate skips unchanged bytes; the 7 released today likely
  skip. publish refuses a card whose live copy drifted, so nothing is overwritten blind.
- Stamps advance only for slugs publish did not refuse, once defect 2 is fixed.
- The planner commit is a live feed change for every visitor to the Meal Plan Builder: 556 price tiles move.
  That is the prices catching up to a week of board data, not new pricing logic.
- The dirty set moves daily (the daily pipeline touched 6 of these slugs). Re-run the dry run immediately before
  the live run and diff its list against the slugs file; a new dirty slug is refused, not carried.

## Open items

- R1: are the four legacy rebuilds live? (Section 3.)
- R2: recommended road (fix then propagate) or interim feed-first? (Section 6.)
- The three defects in section 4 have no owner yet.
- The "95" in the residual does not reproduce against 70 measured; the residual text should be corrected when it
  is closed.
