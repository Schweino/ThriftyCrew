# Companion fences for the four ids minted 2026-08-28 — APPLIED, with the ruling corrected

**Status: applied in commit `4d234888`.** This file was written as a proposal and is kept as the
record of what was measured and why the applied form differs from the registrar's prescription.

Every number here is measured against the estate's OWN identity graph (75,351 rows across the
`recipe` and `staple` namespaces, 32,433 carrying a commodity assignment) — the record of what
`compare-deals.ps1` actually decided — not against a second matcher written for this document. A
Python re-implementation was tried and **abandoned**: it agreed with the graph on only 96.36% of
rows, always by claiming something the board leaves unclaimed, so it was missing constraints and was
not fit to predict from.

---

## 1. The registrar's literal fence would have orphaned seven products — NOT APPLIED as written

The ruling says to add `reduced\s+fat` and `\b2%\s+milk\b` as excludes on `shredded-cheese`.
Measured, that releases four products that `reduced-fat-cheddar` claims **none** of:

| store | product | why it lands nowhere |
|---|---|---|
| Aldi | Happy Farms Shredded 2% Milk Mexican Style Cheese | not cheddar |
| Baker's | Kroger Reduced Fat Mexican Style Shredded Cheese | not cheddar |
| Walmart | Great Value Finely Shredded Reduced Fat Fiesta Cheese Blend, 7 oz | not cheddar |
| Walmart | Great Value Reduced Fat Shredded **Mozzarella** Cheese, 16 oz | not cheddar |

An exclude releases a product; it does not rehome it. A fence that releases more than its new id can
catch converts a *mispriced* row into *no row at all* — invisible rather than wrong.

The `fat[\s-]*free` fence the ruling says to "consider" is worse: **`fat-free-cheddar` has no
commodity rule row at all**, only a vocabulary bid. It would orphan three more products with nowhere
to go. **Not applied.**

### What was applied instead

`shredded-cheese` and `cheddar-cheese-shredded` are fenced with `reduced-fat-cheddar`'s **own
include list**, so by construction what leaves the generic basket is exactly what the new id takes:

```
reduced\s+fat\s+(?:\w+\s+){0,2}cheddar
cheddar[^,]{0,30}reduced\s+fat
2%\s+(?:milk\s+)?(?:\w+\s+){0,2}cheddar
cheddar[^,]{0,25}\b2%\s+milk
```

Blast radius today: **releases 0, orphans 0.** Only one reduced-fat cheddar product exists anywhere
in the graph (a Kraft protein stick, correctly unclaimed — `stick` is excluded); the three backing
the new board row came from the attended 7-store capture, which feeds the board directly and not the
ad graph. So the swallow risk is **latent, not active**: `shredded-cheese`'s patterns *do* match all
three, and it fires the day one appears in a weekly capture. Zero blast radius made today the
cheapest moment to fence it.

## 2. The id minted this morning was itself wrong

`baby-potatoes`, exactly as the registrar prescribed it, claimed **four Idahoan instant *mashed*
potato pouches**. Its `instant` exclude never fires — those product names never say "instant" — and
it had no `mashed` exclude. It also missed `Our Family Potatoes Red Baby Dutch` (baby *follows*
potatoes) and `Petite Spudlings Gourmet Gold Potatoes` (three words where the pattern allowed two).

Applied: `+exclude \bmashed\b`, and two includes —

```
potato(?:es)?[^,]{0,20}\b(?:baby|petite|creamer)\b
(?:baby|petite|creamer)\s+(?:\w+\s+){0,5}potato(?:es)?
```

It now claims 20 products, of which **0** are processed forms.

## 3. A live mispricing found on the way

`coffee-creamer` claims **`Creamer Potatoes, 5 lbs.`** and **`Red Creamer Potatoes`** today — the
Sam's Club row behind the new `baby-potatoes` board cell was being priced as coffee creamer. It
carries `relax_global ['\bcreamer\b']`, which is why. Fenced with `\bpotato(?:es)?\b`, though
`baby-potatoes` at file index 22 already beats `coffee-creamer` at 165 under first-match-wins.

## 4. The potato fences

| rule | claims before | releases | outcome |
|---|---|---|---|
| `red-potatoes` | 23 | 3 | rehomed on `baby-potatoes` |
| `potato` (recipe ns) | 119 | 18 | see below |

The regenerated graph records **20 assignment changes, all `potato` → unclaimed in the RECIPE
namespace.** That is expected, not a regression: `baby-potatoes` is a *weekly* id, so the recipe
namespace has no rule that can claim what `potato` released. They are picked up on the staple side,
whose graph the daily job rebuilds. **No recipe cost moved — measured, 0 of 588.**

## 5. `relax_global` now has a sanctioned path

`add-commodity-rule.ps1` had `-Include`/`-Exclude` and no way to write `relax_global`, so the
ruling's instruction to set it "through add-commodity-rule.ps1" was impossible. It now takes
`-RelaxGlobal` / `-RemoveRelaxGlobal`, and — unlike the other two lists — may have to **create** its
array, placed where `ConvertTo-Json` would have put it (immediately before `"include"`, matching
`frozen-broccoli`). `frozen-cauliflower-rice` now carries `relax_global ["\bfrozen\b"]`.

The script also had **no self-test at all**, so run-gates had never seen it. It has 9 cases now,
driving the real script as a child process against a scratch file. Gates 140 → 141. Its first run
caught a bug in the code it was written for: `@($null).Count` is **1** in PowerShell 5.1, so an
entry with no `relax_global` scored 1 for its absent list and a correct creation was refused as
"changed by 0, expected 1".

## 6. Two ruling claims that were already true, and one that turned out unnecessary

- **`yukon-gold-potatoes` needed no edit.** The ruling says it does not exclude `\bbaby\b`. It does.
  Measured release: 0.
- **`flour` needed no edit.** Its `whole\s+wheat` exclude is already the fence. Release: 0 of 83.
- **The dupe allowlist was not needed.** `audit-commodity-dupes` flags none of the four new ids.

## Still open — not mine to decide

`audit-commodity-dupes` does flag one **pre-existing** pair: `gruyere` (commodities.json) vs
`gruyere-cheese` (recipe-board-everyday.json), "labels identical once normalized". Same food priced
under two ids, which lets the two prices disagree while every per-file check reads green. That is a
registrar question and was left untouched.
