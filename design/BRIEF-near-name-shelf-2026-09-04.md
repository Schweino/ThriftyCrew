# BRIEF: the near-name shelf - stop the mapper minting a name the food DB already holds

queue_id: near-name-shelf-2026-09-04
shipped_commit: (none yet - if this field names a commit, the work is DONE: verify it and report,
do not rebuild)
author: Opus 5, 2026-09-04.
approved by: Brad 2026-08-26 (the shelf itself), 2026-09-04 (the scorer's home).
groundwork already shipped: cbb72739.

## 0. Read these first

1. `meal-prep\pipeline\map-preresolve.ps1` - the header's "ONE ingredient-vocab" paragraph, and the
   evidence block around line 730 (`no food-macros-db row - a label needs transcribing`, and the FDC
   shelf immediately under it). The FDC shelf is the MODEL for this one: read its wording carefully,
   especially "a shelf, not an answer" and why that sentence is load-bearing.
2. `meal-prep\pipeline\ingredient-vocab.ps1` - `-RowsFile` and `-Recall`, shipped in cbb72739 with 11
   fixtures and 5 neuter proofs. The scorer already does the work; nothing calls it yet.
3. `Get-VocabClasses` in map-preresolve (around line 574) - the ONE batched child call for the whole
   term list. The new call is its sibling and must batch the same way; a per-term child call would be
   one PowerShell process per ingredient.

## 1. The defect

When a term has no food-macros-db row, the mapper is told only that a label needs transcribing. It is
never shown the rows the DB already holds, so it transcribes a label and writes a NEW row under a
near name. That is how `Apples` landed beside `Apple`, `Lemons` beside `Lemon` and
`Green Bell Peppers` beside `Green Bell Pepper` - four collisions in 369 rows, every one a food the
DB already had (0b9f8bf5). The write-time collision check catches them at the write; the shelf is
what stops one being minted in the first place.

The VOCABULARY question already gets exactly this treatment - `nearest vocabulary rows: ...` - and
the food-DB question does not.

## 2. The change

In `map-preresolve.ps1`:

1. A `Get-FoodDbNear` beside `Get-VocabClasses`, same shape: ONE child call for every distinct term
   in the batch, `-Missing <termsfile> -RowsFile <food db> -Recall -Json`, returning term ->
   candidates. Reuse `Invoke-Child`; do not write a second child-invocation road.
2. In the `-not $foodDbKnown` branch, ABOVE the FDC shelf (the DB we own is a better first look than
   a keyword search of USDA), add an evidence line naming the near rows WITH THEIR MACROS. The macros
   come from `$FoodDb`, which map-preresolve already holds - the scorer returns names, not nutrition.
3. Word it as a shelf, in the FDC shelf's own register: these rows are near names, none of them may
   be the food, and if one IS the food then CITE IT rather than transcribing a second label for it.
   Say plainly that a near name is not a synonym - `Fresh Parsley` and `Dried Parsley` are different
   foods at different gram weights - and that the form flag on a candidate is the reason to look.
4. Nothing is auto-matched. The 2026-08-26 ruling is explicit: show near names, never auto-match.

## 3. THE OPEN QUESTION THIS BRIEF DOES NOT ANSWER

Measured 2026-09-04 against the live food DB:

    ingredient-vocab.ps1 -Missing <'Green Bell Pepper'> -RowsFile food-macros-db.json -Recall -Top 4
      -> Yellow Bell Pepper, Red Bell Pepper, Black Pepper, Cayenne Pepper

`Green Bell Peppers` - the row that IS the food, and the survivor of that exact duplicate pair - does
not appear. `Get-HeadNoun` returns `pepper` for the query and `peppers` for the row, nothing stems
them, so the head-noun match fails and the row ranks below `Black Pepper`.

That is precisely the miss that let the duplicate be minted, and a shelf that cannot surface it is a
shelf that would not have prevented the thing it exists to prevent.

The fix is a singular/plural stem in `Get-CoreTokens` / `Get-HeadNoun`. It is NOT in this brief
because those functions are SHARED with the vocabulary worklist and the reconciliation road, and a
scoring change there moves what that worklist proposes across the whole estate. **Brad rules on it.**
The options, with what each costs:

  a. stem in the shared scorer. Best answer if it holds: `Apple`/`Apples` becomes a strong candidate
     everywhere, including in the vocabulary worklist where it is equally correct. Blast radius is
     every consumer of Get-Candidates; needs the vocabulary suite's proposals diffed before and after.
  b. stem only under `-Recall`. Smaller blast radius, but it makes the two roads score differently,
     which is one step toward the forked judgment the whole design avoids.
  c. ship the shelf without stemming. The shelf still helps (`Lime Zest` -> `Lemon Zest`/`Orange Zest`
     works today) but it demonstrably misses the plural case, which is a third of the known duplicates.

Do not pick one silently. If the answer is (a), the proof it needs is a before/after diff of what
`-Missing` proposes over the LIVE vocabulary, not a fixture over six fake rows.

## 4. Fixtures

In `map-preresolve.ps1 -SelfTest` (178 assertions today, all green):

1. MUST FIRE: a term with no food-DB row gets a `nearest food-macros-db rows` evidence line naming
   the near rows AND their macros.
2. MUST FIRE: the macros in that line come from the food DB the run was pointed at (use the suite's
   scratch DB seam, not the live file).
3. CLEAN TWIN: a term that HAS a food-DB row gets no shelf at all - the shelf is for the gap.
4. CLEAN TWIN: a term with no near rows says so plainly rather than emitting an empty shelf.
5. MUST FIRE: exactly ONE child call for the whole batch, however many terms have gaps (assert the
   child-invocation count, the way the vocab-class case does).
6. MUST FIRE: the wording carries the shelf rails - none of these may be right, cite rather than
   re-transcribe, a near name is not a synonym.
7. MUST FIRE: a form-flagged candidate is shown WITH its flag, so Dried vs Fresh is visible.

Neuters, one at a time, restored by md5, counts MEASURED: (a) the shelf line removed; (b) `-Recall`
dropped from the child args; (c) the macros dropped from the line; (d) the child called per-term
instead of batched; (e) the shelf emitted for terms that already have a row.

REMEMBER WHAT cbb72739's OWN NEUTERS CAUGHT: three of its five fixtures did not bite on the first
run, because they asserted things that were true whichever rows were scored, and because calling a
predicate directly proves the predicate and not the wiring. Assert against something that can only be
true if the food DB was the row set, and exercise the switch through the CALL, not the function.

## 5. Gates
`map-preresolve.ps1 -SelfTest` (178 -> more, nothing removed, diff the case NAMES),
`ingredient-vocab.ps1 -SelfTest`, and `hunt-daemon.py --selftest` (map-preresolve is on the daemon's
map lane; it is a 5-minute suite, run it in the background and read the file).

## 6. Things you will be tempted to do, and must not
- Do not write a second head-noun scorer. That is the whole reason cbb72739 exists.
- Do not auto-match a near name. Brad ruled on 2026-08-26: show them, never match them.
- Do not put the food DB's macros in the scorer's return. The scorer ranks names; map-preresolve owns
  the macros and already holds them.
- Do not fix the plural miss on your own judgment. Section 3 is a question, not a task.
