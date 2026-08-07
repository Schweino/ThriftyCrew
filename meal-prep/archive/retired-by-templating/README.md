# Retired by prose templating (2026-08-08)

These three scripts existed to keep prose MONEY LITERALS in agreement with each spec's stat block. On
2026-08-08 the catalog migrated to {{cost_ps}}/{{cal}}/{{protein}} tokens (pipeline\migrate-prose-tokens.ps1,
verified by a 1084/1084 byte-identical card rebuild), and lib\render-tokens.ps1 now substitutes the spec's
own stat at render. There is no prose figure left to re-anchor, so:

  reanchor-moved-prose.ps1          moved prose dollars to follow a recompute (diffed against the
                                    pre-recompute manifest snapshot). Its blind spot - a figure already
                                    wrong BEFORE the move - is what let 15 slow-cooker specs understate
                                    cost for weeks.
  repair-unreachable-prose-money.ps1  built 2026-08-07 to fix exactly that blind spot; lived one day.
  validate-prose-reanchor.ps1       checked the reanchor pair had both run.

The surviving invariant lives in reanchor-all.ps1: NO money literal in the five prose surfaces, and every
token must expand. A batch promote that reintroduces literals fails the daily chain within a day; the fix
it names is migrate-prose-tokens.ps1 -Slugs <slug> -Apply.
