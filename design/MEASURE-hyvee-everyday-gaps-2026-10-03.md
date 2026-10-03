# MEASURE: does Hy-Vee carry the five no-fallback sale items at an everyday price? (2026-10-03)

Ruling measured: R7.3 in `design/PLAN-weekly-root-families-2026-10-02.md` Phase 7 (Brad, 2026-10-03, "Measure first
(Recommended)"). Queue item 2026-09-28-e40f92. Nothing here changes the pull, `commodities.json` or any price.

## 1. Verdict

**All five are CARRIED-EVERYDAY at Hy-Vee Omaha #02 (storeId 1466): 5 of 5 judged, 0 COULD-NOT-LOOK, 0 NOT-CARRIED.**
Each has at least one product matching the commodity's own include and exclude rules that the store answered with
`onSale=false` and `price = basePrice`.

So the gap is not the store. It is three defects in our own lanes:

1. **SCOPE (the pull cannot ask).** `grocery/pull-regular-hyvee.ps1` re-reads known product ids only. Its work list is
   yesterday's `hyvee-regular-*.json` plus the Hy-Vee entries in `grocery/product-urls.json`, and none of the five has
   either (section 5 gives the controls).
   Its sale-fallback block promotes a fallback only when a work item carries that commodity id AND a product id
   (`if ($fIdx.Count -eq 0 ...) { continue }`), so a commodity with no row is skipped without a word. The pull's own
   `-DryRun` on main's 2026-10-02 inputs prints `Hy-Vee: sale fallbacks owed 5, 5 in today's plan, 0 promoted to rank
   0 behind the expiries`, and `sale-fallback-asked.json` has never recorded any of the five.
2. **The "terms attempted" check is vacuous for Hy-Vee.** `grocery/audit-sale-fallback.ps1` `Test-TermsWereAttempted`
   matches commodity-search terms against the everyday file's `capture_terms`. All 1,549 Hy-Vee capture_terms on
   2026-10-02 are product keys (`product-NNNN-<pid>`), so no term is ever known, and the function returns `$true` when
   none is (`if ($known -eq 0) { return $true }`). Run on the real file it answers True for `chicken drumsticks` and
   equally for the nonsense term `zzz-no-such-commodity-term`. Every Hy-Vee gap therefore reads `terms_attempted=true`
   and is never shown UNPROVEN, which is why the queue item read as "asked and not found".
3. **Discovery finds them and nothing carries them in.** `grocery/discover-hyvee.ps1`, the only Hy-Vee search lane,
   already docketed four of the five in `grocery/out/hyvee-discovery.json` with product ids (drumsticks 2 rows,
   gruyere 10, quinoa 9, white wine 79), several marked "we hold nothing here". Its docket feeds adjudication only, by
   design, so no id reaches the pull. Frozen cauliflower rice has 0 rows because it has **no term in
   `grocery/commodity-search.json`**, and discovery skips a commodity with no term.

## 2. Rubric (written before any response was read)

Unit: one verdict per commodity at the store the pull itself sends (storeId and locationId from `hyvee-store-lib.ps1`).

- CARRIED-EVERYDAY: a product in a captured response matches the commodity (its own include, none of its excludes) and
  the store's product lookup answers it at storeId 1466 with no active sale (`onSale=false`, `price = basePrice`).
- CARRIED-SALE-ONLY: matches exist but every one is on sale with no readable regular price.
- NOT-CARRIED: only from a settled 200 response under the commodity's own term plus at least one broader term.
- COULD-NOT-LOOK: blocked, unrendered, unsettled, or the request could not be reproduced. A CAPTCHA stops the look.

Bar: 5 of 5 verdicts, each backed by a saved response. Any COULD-NOT-LOOK is counted, never folded into NOT-CARRIED.
Result against the bar: 5 of 5 met. The four empty-result causes (gr-17) did not arise: every search returned HTTP 200
with a non-empty JSON `results` array from the store's own search API (no render step, so unrendered and unsettled do
not apply), and every lookup resolved `answered` for storeId 1466 (0 threw, 0 empty, 0 other-store). No wall seen.

## 3. One row per item

Search counts are rows returned / rows matching the commodity's own rules. Lookups are the pull's own GraphQL call.
Only the commodity's own include and exclude were applied, not the global excludes, so some matches are off-target
(noted); each verdict rests on a clean product.

| Commodity | Terms asked (count of rows / matched) | Nearest everyday matches (product id, size, price, onSale) | The sale item itself | Verdict |
|---|---|---|---|---|
| chicken-drumsticks | `chicken drumsticks` 90/4; `drumsticks` 36/4; `smart chicken drumsticks` 76/4 | 65781 Smart Chicken Air-Chilled Family Pack Drumsticks, $1.99/lb, false; 65780 Smart Chicken Air-Chilled Drumsticks, $2.29/lb, false; 2825565 Hy-Vee True Chicken Drumsticks 5 lb, $5.94, false | 65800 Hy-Vee Family Pack, $1.88/lb on sale, base $1.99. The ad's "Smart Chicken $1.99 lb" equals 65781's regular price | CARRIED-EVERYDAY |
| frozen-cauliflower-rice | no term exists; asked `riced cauliflower` 90/8; `cauliflower rice` 90/8; `nothing but the truth riced cauliflower` 80/8 | 2276661 Birds Eye Riced Cauliflower 10 oz, $3.99, false; 2669178 Hy-Vee Riced Cauliflower Steam in Bag 10.5 oz, $3.49, false | 4126250 Nothing But The Truth Organic Riced Cauliflower 8.5 oz, $2.99 on sale, base $3.99 | CARRIED-EVERYDAY |
| gruyere | `gruyere cheese` 53/9; `gruyere` 30/8; `emmi gruyere` 16/6 | 2992905 Red Apple Cheese Gruyere 7 oz, $4.87, false; 2426076 Finlandia Gruyere 7 oz, $7.99, false | 381345 Emmi Le Gruyere AOP 6 oz, $9.99 on sale, base $12.99 | CARRIED-EVERYDAY |
| quinoa-uncooked | `quinoa` 23/6; `nothing but the truth quinoa` 74/4 | 4141700 Nothing But The Truth Organic White Quinoa 1 lb, $4.99, false; 3027854 Hy-Vee Tri-Color Quinoa 16 oz, $6.99, false; 2987831 White Quinoa 32 oz, $10.99, false | 4143800 Nothing But The Truth Organic White Quinoa 16 oz, $4.49 on sale, base $5.99 | CARRIED-EVERYDAY |
| white-wine | `white wine` 90/53; `chardonnay` 90/48; `sauvignon blanc` 90/46; `kim crawford` 9/6 | 79295 Sutter Home Sauvignon Blanc 750 ml, $6.99, false; 76664 Barefoot Chardonnay 750 ml, $7.98, false; 104711 Kendall-Jackson Sauvignon Blanc 750 ml, $13.99, false (15 looked up, 9 not on sale) | 4045543 Kim Crawford Pinot Grigio 750 ml, $13.99 on sale, base $17.99 | CARRIED-EVERYDAY |

Off-target rows that passed the commodity's own rules (a matcher note for whoever admits ids, not a verdict input):
gruyere matched Wood River and Finlandia "Cheddar Gruyere" blends; quinoa matched `HU Vanilla Quinoa Crispy Choco`;
cauliflower rice matched a CAULIPOWER bowl and a Green Giant riced mix with cheese sauce. Admitting an id from
discovery must pick a plain product, as the table does.

## 4. Recommendation per item (the fix is the next ruling's)

- **All five: admit a plain everyday product id into the pull's work list**, through the existing discovery docket
  and `adjudicate-discovery.ps1` into a Hy-Vee `product-urls.json` entry, so the pull's sale-fallback block finds a
  work item with a product id. Candidates from this measurement: drumsticks 2825565 or 65781; cauliflower rice 2276661
  or 2669178; gruyere 2992905 or 2426076; quinoa 4141700 or 3027854; white wine 79295 or 76664. Not one is recorded
  not-carried.
- **frozen-cauliflower-rice: add a search term** to `commodity-search.json` (`riced cauliflower`, which returned 8
  matching rows), or discovery can never find it and the audit can never test it.
- **`pull-regular-hyvee.ps1`: speak the skip.** A sale fallback owed with no work item carrying a product id should
  be counted and named in the run line (today it reads "5 in today's plan, 0 promoted" with no reason), and ideally
  routed to discovery for that commodity.
- **`audit-sale-fallback.ps1`: make "attempted" provable for Hy-Vee.** For a store whose capture_terms are product
  keys, `Test-TermsWereAttempted` cannot speak and must return UNPROVEN, not True; the honest test there is whether
  the store's work list held a product for the commodity.

## 5. Harness

Harness: a one-off scratch script, not committed (ms-07: a one-off keeps its description). Run 2026-10-03 01:09 local,
sequential, 600 ms between requests, 15 searches and 42 lookups, all read-only. It wrote only to a scratch directory.

1. Search: the request verbatim from `grocery/discover-hyvee.ps1` `HV-Search`: POST
   `https://www.hy-vee.com/aisles-online/api/search/products`, body `pageNumber 1, pageSize 90, searchFilters [],
   searchTerm <term>, sortDirection RELEVANCE, storeId 1466, pageViewId <guid>`, same User-Agent and correlation header.
2. Match: each result's `description` against the commodity's own `include` and `exclude` in `grocery/commodities.json`.
3. Lookup: `Get-HyVeeLookupBody`, `Test-HyVeeLookupBody` and `Resolve-HyVeeLookupOutcome` taken from
   `grocery/pull-regular-hyvee.ps1` by the PowerShell AST (not retyped), the persisted document from
   `grocery/hyvee/query-b64.txt`, POST `.../api/graphql/two-legged/getProductDetailsWithPrice` with the pull's headers,
   storeId 1466, locationId 09e8f4f0-e614-4b86-9285-c9c3dbff0d85 (both from `grocery/hyvee-store-lib.ps1`).
4. Pull behaviour: `pull-regular-hyvee.ps1 -DryRun -OutDir <scratch copy of main's grocery/out: hyvee-regular files,
   sale-fallback-gaps.json, sale-fallback-asked.json, comparison-2026-09-30.json, candidates-2026-09-30.json>`, exit 0,
   `HYVEE-DRYRUN-COMPLETE no request issued, nothing written`.
5. The vacuous check: `Test-TermsWereAttempted` taken from `grocery/audit-sale-fallback.ps1` by AST, run against the
   capture_terms of main's `grocery/out/regular/hyvee-regular-2026-10-02.json`.

Blobs of every file the run read, at origin/main 3984bafd8 (2026-10-03):

- `grocery/pull-regular-hyvee.ps1` blob 5a703da069e09258b40684cd0e1f3825c3a181b4
- `grocery/discover-hyvee.ps1` blob cac2b7458b02a6eab8b4352cb34accacc53d3de9
- `grocery/audit-sale-fallback.ps1` blob e4e35c76c57dfec51f5664f766ce4e4d7574ecaa
- `grocery/hyvee-store-lib.ps1` blob 59d91acaed34f33457947f48030f12ff9606b428
- `grocery/hyvee/query-b64.txt` blob 8aa7ff7daa56278607d1d7561eaded5b2eb1409b
- `grocery/commodities.json` blob 64f531d65189323eee177fdef5ec4d4bbed34404
- `grocery/commodity-search.json` blob 7edf03fd345f31bc2122ac206b322b93b10ad6b8
- `grocery/capture-policy-lib.ps1` blob 6d7396b81f9c2e7dcf00a46a9a70f3e10144bfa0

Inputs not in git (gitignored, read from the main checkout): `grocery/out/sale-fallback-gaps.json` generated
2026-10-02 08:31; `grocery/out/regular/hyvee-regular-2026-10-02.json` (1,546 deals, 1,549 capture_terms);
`grocery/out/hyvee-discovery.json` written 2026-10-02 08:31 (3,218 rows).

The negative results, each with its control (preflight item 10): `grocery/product-urls.json` (blob
62ce4eb33f573ba72c75108b684d35072ade9e53) holds a Hy-Vee entry for 472 of its 661 items, including the control
five-spice-powder, and for none of the five (my first lookup read the top level, found 0 of 3, and was discarded as
broken before it carried anything). In `hyvee-regular-2026-10-02.json` the same name scan that found 0 drumstick,
gruyere and quinoa rows found 2 cauliflower and 11 wine rows, all fresh heads, vinegars and mustards.

## 6. Knowledge consulted

- `.claude/rules/grocery.md` gr-17: "A 200 with a correct selector and ZERO ROWS has FOUR causes ... UNCHECKED IS
  NEVER NOT-CARRIED ... Prefer the page's own Fetch/XHR JSON call." Used: both requests are the store's JSON APIs.
- `.claude/rules/grocery.md` gr-11: the pull "asks first for rows withheld only for its store
  (Get-HyVeeUncoveredIds) and builds its lookup from $script:HvRequest*". Used: the lookup body is the pull's own.
- `.claude/rules/measurement.md` ms-01, ms-03, ms-07: denominators, the bar before the run, blobs not hashes.
- Memory `hyvee-discovery-f1` and `pull-depth-findings` (2026-08-01, 2026-07-31): the pull "is a REFRESH, not a
  pull" whose work list is two closed sets. Confirmed again here, and it is the whole of defect 1.
- Memory `bot-wall-verdict-discards-its-evidence`: re-probe before calling a store cold. No wall arose.
- `experiment-craft/analysis-preflight.md` items 2, 3, 5, 10; item 10 caught the broken product-urls lookup above.

Caveat on currency: prices move with the weekly ad (2026-09-28 to 2026-10-04). The verdict is about carriage, which a
week's sale does not change; the prices in section 3 are evidence of what the store answered that night, never a
pricing input.
