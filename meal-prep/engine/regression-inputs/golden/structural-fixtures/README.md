# structural-fixtures - proof that the structural lane can still see a defect

FROZEN. Never regenerate these from live data. A guard that reports nothing is indistinguishable from a
guard that is broken, so every check in `engine\structural-lib.ps1` ships a world where it MUST fire and
a clean twin where it MUST stay silent (the rule `grocery\test-auditors.ps1` was written to enforce).

A two-recipe world, small enough to verify by hand:

| item | shape | package |
|---|---|---|
| MF Flour | bulk | pantry 907 g ("2lb bag") |
| MF Beans | not bulk | buy 425 g ("15oz can") |

`mf-one` uses 1000 g flour + 800 g beans; `mf-two` uses 425 g beans. At 0.002 $/g flour and 0.004 $/g
beans that is, entirely by hand:

```
mf-one  util      flour 1000 x .002 = 2.00     beans 800 x .004 = 3.20    batch 5.20
        packages  starter ceil(1000/907 - .02) = 2 -> 2 x 907 x .002 = 3.63
                  buy     ceil( 800/425 - .02) = 2 -> 2 x 425 x .004 = 3.40
        true      2.00 (bulk at util) + 3.40 = 5.40      pantry add 3.63 - 2.00 = 1.63
        first run 5.40 + 1.63 = 7.03      per serving 5.20/14 = .37   true .39
mf-two  util      beans 425 x .004 = 1.70      buy ceil(425/425 - .02) = 1 -> 1.70
        batch/true 1.70   pantry add 0   first run 1.70   per serving .12
```

| world | the defect | check that must fire |
|---|---|---|
| `clean` | none | all silent |
| `mustfire-missing-row` | `mf-one` costed but absent from costed.json | C1 |
| `mustfire-orphan-row` | a row for `mf-ghost`, a recipe with no spec | C1 |
| `mustfire-stale-grams` | costed line says 700 g where the spec says 800 g | C2 |
| `mustfire-bad-ceil` | `buy_n` 1 where ceil(800/425 - .02) is 2 | C9 |
| `mustfire-bad-total` | `cost_first_run` 5.40 - the pantry fold dropped | C7 |

The founding bug is `mustfire-missing-row`. On 2026-08-06 the `-Slugs` splice in `cost-recipes.ps1` could
only REPLACE an existing costed row, so 29 brand-new burrito recipes were costed correctly, found no row
to overwrite, and were dropped without a flag - an empty `cost-flags.txt` next to a silently missing
recipe. `mustfire-stale-grams` and `mustfire-bad-ceil` are the same family one step later: a spec edited
without a recost, which is how `pipeline\cost-render-lib.ps1` came to carry its own ceil self-test.
