# Batch 2 (agent A, items 1-25) - hijack & relax_global findings

Scope: nectarines, apricots, pomegranates, papaya, fresh-cranberries, plantains, coconut,
medjool-dates, dried-cranberries, prunes, shallots, yukon-gold-potatoes, mini-sweet-peppers,
serrano-peppers, anaheim-peppers, habanero-peppers, beets, turnips, parsnips, rutabagas, leeks,
collard-greens, mustard-greens, turnip-greens, swiss-chard.

All patterns below verified against the live `commodities.json` include/exclude lists and the
`GLOBAL_EXCLUDE` list in `compare-deals.ps1` on 2026-07-26.

## relax_global: NONE needed

No candidate in this slice has product names that inherently contain a global-exclude token.
Closest call checked: "Sweet Snacking Peppers" (mini-sweet-peppers) does NOT trip the global
`\bsnack\b` token because "snacking" has no word boundary after "snack". Pomegranate/prune/apricot
juice, canned greens, etc. all hit global tokens, but those are wrong-class products we WANT
blocked, so no relaxation.

## FIX REQUIRED - beets (fresh) vs existing `canned-beets`

`canned-beets` includes bare `\bbeets?\b` and sits earlier in the array. Its excludes are only
`\bjuice\b, \bfresh\b, greens?, powder, chips?, \bfrozen\b` - produce named "Red Beets", "Golden
Beets", "Beets Bunch" (stores rarely say "fresh") is HIJACKED by the canned item.

**Add to `canned-beets`.exclude:**

```
red\s+beets?\b
golden\s+beets?\b
\bbunch(?:ed)?\b
loose\s+beets?\b
```

(Real canned titles - "Del Monte Sliced Beets", "Aunt Nellie's Pickled Beets", "Libby's Cut Beets" -
never use these produce name forms, so nothing canned is lost.)

My fresh `beets` rule is deliberately anchored to those same produce forms (red/golden/organic/
bunched/loose/fresh beets) as a boundary exception to the never-require-fresh lesson.
**Residual ambiguity:** a product titled ONLY "Beets" stays with `canned-beets` (first match);
irreducible from the name alone.

## FIX REQUIRED - dried-cranberries vs existing `raisins`

`raisins` includes `raisins?` with NO word boundary. "Craisins" contains the substring "raisins",
so every Craisins-branded dried-cranberry product is hijacked by `raisins` (its exclude list has no
cranberry/craisin token - verified).

**Add to `raisins`.exclude:**

```
craisins?
cranberr
```

(`cranberr` also covers "Dried Cranberries & Raisins" blend packs. No real raisin product contains
either token.) Non-Craisins titles like "Store Brand Dried Cranberries" contain no "raisin"
substring and were never at risk.

## FIX REQUIRED - anaheim-peppers vs existing `canned-green-chilies`

`canned-green-chilies` includes bare `green\s+chil(?:e|i)e?s?` and only excludes `\bfresh\b` (plus
tomato/ro-tel/jalape/etc.). Fresh Anaheim/Hatch produce named "Anaheim Green Chile" or "Hatch Green
Chile Peppers" (stores rarely say "fresh") is hijacked by the canned item.

**Add to `canned-green-chilies`.exclude:**

```
anaheims?\b
```

Do NOT exclude `\bpeppers?\b` there - real canned titles like "Kroger Diced Green Chile Peppers,
4 oz" would be lost.

My `anaheim-peppers` include is anchored to `anaheims?\b` only; `hatch` was deliberately omitted
(Hatch is a canned-goods brand). **Residual ambiguity:** seasonal fresh product titled only
"Hatch Green Chile" still routes to `canned-green-chilies`; revisit in Hatch season (Aug-Sep) if it
shows up in captures.

## Verified SAFE - no commodities.json change needed

- **mustard-greens vs `mustard`**: `mustard` (`\bmustard\b`) already carries a `greens` exclude,
  so bunches fall through to my full-phrase `mustard\s+greens?` rule. No change.
- **prunes vs `plums`**: `plums` (`\bplums?\b`) already excludes `dried`, so "Sunsweet Dried Plums"
  falls through to my rule. Bare "Prunes" shares no token with plums. No change.
- **mini-sweet-peppers vs `bell-peppers`**: `bell-peppers` already excludes `mini\s+sweet`. My rule
  excludes `\bbell\b` so a "Mini Bell Peppers" SKU stays with bell-peppers. No change.
- **nectarines vs `peaches`**: `peach(es)?` cannot match nectarine names; no shared token. No change.
- **plantains vs `bananas`**: `banana` include shares no token with "plantain". No change.
- **shallots / leeks vs `onions` / `green-onions`**: no shared tokens in either direction
  (`\bonion`, `vidalia`, `green onions`, `scallions`). No change.
- **coconut vs `coconut-oil` / `coconut-milk-canned`**: both sit earlier in the array and their
  tokens (`\boil\b`, `\bmilk\b`) are excluded in my whole-coconut rule; double-protected. No change.
- **pomegranates vs `pomegranate-molasses`**: molasses item matches its own phrase first AND
  `molasses` is excluded in my rule. No change.
- **fresh-cranberries vs `cranberry-juice` / `cranberry-sauce`**: both full-phrase includes match
  their own products first; my rule also excludes juice/sauce/cocktail/jellied. No change.
- **apricots vs `jelly`**: "Apricot Preserves" routes to jelly (earlier, `preserves` include) and my
  rule excludes preserves/jam/jelly anyway. No change.
- **yukon-gold-potatoes vs `russet-potatoes` / `red-potatoes` / `sweet-potatoes` /
  `instant-mashed-potatoes`**: no include-token overlap; my rule excludes russet/sweet/instant/
  mashed as belt-and-suspenders. No change.
- **swiss-chard / collard-greens vs `kale` / `spinach`**: no shared tokens; `kale` excludes
  `\bblend\b` and my rules exclude blends too, so "Kale & Chard Blend" matches neither. No change.

## Intra-batch boundaries (both sides are mine - handled inside rules-b2-a.json)

- **turnips vs turnip-greens**: `turnips` excludes `greens?\b` and MUST stay ordered before
  `turnip-greens` on merge (it is, in my file).
- **fresh-cranberries vs dried-cranberries**: fresh excludes `\bdried\b` + `craisins?`; dried
  requires the word "dried" or the Craisins brand. Order-independent.
- **turnips vs rutabagas**: mutual excludes; a combined "Turnips & Rutabagas" listing matches
  neither rather than being order-hijacked.
