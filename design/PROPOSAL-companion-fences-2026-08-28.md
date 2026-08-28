# Companion fences for the four ids minted 2026-08-28 — PROPOSAL, nothing applied

Brad asked for the registrar's companion edits drafted and measured, not applied. This is that draft.
Every number below is measured against the estate's OWN identity graph (75,351 rows across the
`recipe` and `staple` namespaces, 32,433 of them carrying a commodity assignment) — not against a
second matcher written for this document, which would prove nothing if it disagreed with the board's.

**Status: NOTHING IN THIS FILE HAS BEEN APPLIED.** The four ids are live and priced; these fences
protect them.

---

## The headline: the registrar's literal prescription would orphan seven products

The ruling says to add `reduced\s+fat` and `\b2%\s+milk\b` as excludes on `shredded-cheese`.
Measured, that releases four products — and `reduced-fat-cheddar` claims **none** of them:

| store | product | why it lands nowhere |
|---|---|---|
| Aldi | Happy Farms Shredded 2% Milk Mexican Style Cheese | not cheddar |
| Baker's | Kroger Reduced Fat Mexican Style Shredded Cheese | not cheddar |
| Walmart | Great Value Finely Shredded Reduced Fat Fiesta Cheese Blend, 7 oz | not cheddar |
| Walmart | Great Value Reduced Fat Shredded **Mozzarella** Cheese, 16 oz | not cheddar |

An exclude releases a product; it does not rehome it. A fence that releases more than its new id can
catch converts a *mispriced* row into *no row at all* — and a commodity nobody prices is invisible
rather than wrong, which is the harder failure to notice.

The `fat[\s-]*free` fence the ruling says to "consider" is worse: **`fat-free-cheddar` has no
commodity rule row at all.** It is a vocabulary bid only. Excluding fat-free from `shredded-cheese`
would orphan three more products with nowhere whatsoever to go.

> **Recommendation: do not apply the broad `reduced\s+fat` fence, and do not apply the fat-free fence
> at all.** Use the narrow form below.

## The corrected fence: mirror the new id's own includes

Build `shredded-cheese`'s exclude from `reduced-fat-cheddar`'s **include** list. Then, by
construction, exactly what leaves the generic basket is what the new id takes.

```
reduced\s+fat\s+(?:\w+\s+){0,2}cheddar
cheddar[^,]{0,30}reduced\s+fat
2%\s+(?:milk\s+)?(?:\w+\s+){0,2}cheddar
cheddar[^,]{0,25}\b2%\s+milk
```

Measured blast radius today: **releases 0, orphans 0.** The reason is worth stating plainly — only
one reduced-fat cheddar product exists anywhere in the graph (a Kraft protein stick, correctly
unclaimed because `stick` is excluded). The three products backing the new board row came from the
attended 7-store capture, which feeds the board directly and not the ad graph.

So the swallow risk is **real but latent**: `shredded-cheese`'s patterns *do* match all three
(verified), and `cheddar-cheese-shredded` matches the Baker's one. It fires the day one of them
appears in a weekly capture. That makes today — zero blast radius — the cheapest possible moment to
put the fence in.

```bash
grocery/add-commodity-rule.ps1 -Id shredded-cheese -DryRun -Why "reduced-fat-cheddar was minted 2026-08-28; these mirror its includes exactly so nothing else is released" -Exclude 'reduced\s+fat\s+(?:\w+\s+){0,2}cheddar','cheddar[^,]{0,30}reduced\s+fat','2%\s+(?:milk\s+)?(?:\w+\s+){0,2}cheddar','cheddar[^,]{0,25}\b2%\s+milk'
```

```bash
grocery/add-commodity-rule.ps1 -Id cheddar-cheese-shredded -File grocery/recipe-commodities.json -DryRun -Why "the full-fat id must not swallow the fat-tier variant" -Exclude 'reduced\s+fat\s+(?:\w+\s+){0,2}cheddar','cheddar[^,]{0,30}reduced\s+fat','2%\s+(?:milk\s+)?(?:\w+\s+){0,2}cheddar','cheddar[^,]{0,25}\b2%\s+milk'
```

## The potato fences — real, immediate, and worth doing

Unlike the cheese, these move live rows today.

| rule | claims now | releases | rehomed on `baby-potatoes` | orphaned |
|---|---|---|---|---|
| `red-potatoes` | 23 | 3 | 3 | 0 |
| `potato` (recipe ns) | 119 | 18 | 17 | 1 |

That is 21 real products — Walmart's *Fresh Red Petite Potatoes* (the very row that backs the new
board cell), Family Fare's *Baby Dutch*, Fareway's *Baby Red*, and Baker's petite line — currently
priced as generic russet-class potatoes at roughly a third of what they cost.

**This needs one widening of `baby-potatoes`'s own includes.** With the registrar's includes as
minted, 5 of those 18 orphan: `Our Family Potatoes Red Baby Dutch` puts *baby* after *potatoes*, and
`Petite Spudlings Gourmet Gold Potatoes` has three words between *petite* and *potatoes* where the
pattern allows two. Adding these two patterns takes the orphan count from 5 to 1:

```
potato(?:es)?[^,]{0,20}\b(?:baby|petite|creamer)\b
(?:baby|petite|creamer)\s+(?:\w+\s+){0,4}potato(?:es)?
```

The single remaining orphan is `Private Selection Petite Spudlings Gourmet Red and Gold Potatoes`
(five words between *petite* and *potatoes*). `{0,5}` clears it; I have not proposed that because
each widening step is a wider net, and one Baker's SKU is a poor reason to take it. Your call.

## Two things in the ruling that are already true, and one with no tool

- **`yukon-gold-potatoes` needs no edit.** The ruling says it "already excludes petite/creamer but
  NOT `\bbaby\b`". It *does* exclude `\bbaby\b` today — measured release with that pattern: 0.
- **`flour` needs no edit.** The ruling was right: its `whole\s+wheat` exclude is already the fence.
  Measured release: 0 of 83.
- **`frozen-cauliflower-rice` needs `relax_global ["\bfrozen\b"]`, and there is no sanctioned path.**
  The ruling says this goes "through add-commodity-rule.ps1". It cannot: that script takes
  `-Include`, `-Exclude`, `-RemoveInclude`, `-RemoveExclude` and has no `relax_global` support at
  all. `frozen-broccoli` and `frozen-vegetables` both carry the field, so the shape is settled — what
  is missing is the gated way to write it. Either `add-commodity-rule.ps1` grows a `-RelaxGlobal`
  parameter (with the same surgical-write proof it already applies), or this is a hand edit. **Until
  it is set, the global frozen exclude drops every ad for this id** — it keeps its everyday board
  price and simply never sees a sale.

## Dupe allowlist

Not yet drafted. The registrar named four pairs (`reduced-fat-cheddar` vs `cheddar-cheese-shredded`,
`fat-free-cheddar`, `shredded-cheese`; plus the potato and cauliflower families). `audit-commodity-dupes.ps1`
is the consumer; these should go in before it next runs or it will report the new ids as duplicates.

## If you approve

Each fence ships with a neuter-proved fixture pinning what it releases and what claims it instead —
the measurement above is the fixture's content, so a later widening that starts orphaning products
turns the gate red instead of quietly emptying a basket.
