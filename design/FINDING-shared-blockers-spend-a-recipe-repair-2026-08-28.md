# A recipe's one repair cycle is spent by other recipes' defects

Wave 11 cannot be published. The reason is not a defect in the recipe — it is a policy that charges a
recipe for problems that were never about it.

## What happened to `honey-bbq-chicken-mac-and-cheese`

Its first audit raised **three blockers**: one recipe-local, two shared-data.

| # | kind | what |
|---|---|---|
| 1 | shared-data (writer) | `audit-spec-contradictions` exits 1 — three PHANTOM specs, in **three other recipes** |
| 2 | shared-data (pricer) | `cheddar-cheese` priced by **mozzarella** — a board defect across the catalog |
| 3 | recipe-local (writer) | a doubled gram token in this spec |

The repair cycle fixed #3 and re-dispatched, claiming "the blocker was recipe-local". The re-audit
found #1 and #2 still open and returned NO-GO. Its own process note:

> the repair cycle must read the FULL blocker list of the audit it is repairing, or waves bounce
> twice for nothing.

`plan_trim` then applied its rule — *"A slug that has already had its one repair cycle is terminal"* —
and settled the recipe to `rejected-audit`, which is **not a key in hunt-run's transition table**.
There is no way out, and no `-Revive` anywhere in the pipeline.

## So it died with zero open defects of its own

Its one recipe-local blocker was fixed and verified. It was killed by two estate-wide data problems,
**and both are now closed**:

- `audit-spec-contradictions` exits **0** (another session fixed the three phantoms today, `0f1a70ae`)
- the cheddar line is fixed — that was this morning's mint, `c682bfb4`

The audit's own remediation says "then this wave can come back for GO". It cannot. The wave manifest
was reconciled to empty at 13:11:13 and the recipe put in a terminal state.

## The policy defect

`plan_trim` counts repair cycles per slug without asking what the blockers were *about*. A recipe can
therefore be made terminal by:

- a gate that is red because of a **different recipe's** spec, or
- a **board-wide pricing** defect owned by the pricer,

neither of which the recipe's owner can fix and neither of which says anything about the recipe. Two
sessions can then burn a recipe's entire repair budget without ever touching it.

A recipe with **no open recipe-local blocker** should not be terminal. The blocker list already
labels its entries `(shared-data, owner: X)` versus `(recipe-local, owner: X)` — the information
needed to make this distinction is already written down in every audit; nothing reads it.

## Options

1. **Fix the policy** — only a recipe-local blocker consumes that recipe's repair budget; a NO-GO
   caused solely by shared-data blockers trims the wave and returns the slugs to `qa-passed` to be
   re-waved once the shared repair lands. Needs a change to `plan_trim` and the daemon's settle path,
   with fixtures, and it is a rule change so it is Brad's call.
2. **Revive this one recipe** deliberately — there is no sanctioned tool, so it means either building
   a gated `-Revive` (state file + ledger + a legal transition) or an explicitly authorised one-off
   edit. I have not touched the state file: walking a recipe into a state to reach a verdict is the
   exact lie the state machine's own comments exist to prevent.
3. **Let it go** — accept the recipe as lost and re-source later. Note the dedup ledger will likely
   recognise the dish, so "later" may mean never.

Recommended: **1, then 2**, because the policy will do this again to the next recipe that is blocked
by a gate it does not own — and today there are 10 slugs in `rejected-audit` in this run alone.
