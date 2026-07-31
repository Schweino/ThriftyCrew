# triage-plans - the handoff contract between the Triage Reviewer and the Triage Developer

The grocery alert triage runs as two agents, on purpose:

- **triage-reviewer** (Fable, high effort, READ ONLY) reads the open alerts, proves what actually went
  wrong, finds the holistic root cause, and writes ONE plan file here.
- **triage-developer** (Opus, max effort, full tools) implements that plan, ships it through the existing
  gates, commits, pushes, and closes the queue items.

Diagnosis and implementation are different jobs and they fail in different ways. Splitting them means the
plan is written by a model that has read every flagged row and nothing else, and executed by a model that
never has to re-derive why. The plan file is the ONLY handoff. Nothing important may live in the dispatch
message, because the message is gone the moment the agent ends and the plan is what gets committed with
the fix.

## File

`grocery/triage-plans/plan-<yyyy-MM-dd>.json` (one per triage run; add `-2`, `-3` for extra rounds the
same day). It is TRACKED IN GIT and the developer commits it alongside the fixes, so the reasoning ships
with the change and a future reader can see why a rule exists.

## Schema

```jsonc
{
  "generated": "2026-07-31T06:40:00",     // ISO, reviewer's clock
  "round": 1,                              // 2 = a bounce-back round (max 2, see below)
  "board_week": "2026-07-30",              // week_of of the newest comparison the reviewer read
  "queue_ids_seen": ["2026-07-30-abc123"], // EVERY open id from triage-queue.json, no exceptions
  "items": [
    {
      "queue_id": "2026-07-30-abc123",
      "subject": "Grocery: 71 NEW price flag(s) - 2026-07-30",

      // WHAT IT IS. One of:
      //   real-economics   - the number is correct (bulk pack, store-brand, clearance). No code change.
      //   wrong-product    - the cell prices a product that is not the commodity.
      //   parse-basis-bug  - the price is real but the size/basis/arithmetic is wrong.
      //   capture-gap      - a store did not refresh; data is missing, not wrong.
      //   infra            - a job, log, schedule, credential or wall (CAPTCHA) problem.
      //   no-code-change   - handled by another owner (Wednesday browser agent, daily self-heal).
      //   needs-brad       - a purchase, a wall, or a judgment call about what a commodity SHOULD mean.
      "classification": "wrong-product",

      // WHAT WAS ACTUALLY READ. Rows, not adjectives. Store, product name, size, ad price, per-unit.
      // A classification with no evidence line is not reviewable and the developer must bounce it.
      "evidence": [
        "lemons | Sam's Club | 'Starry Mini Cans Lemon Lime, 7.5 fl. oz., 30 pk.' | $15.98 / 225 fl oz | $0.5413/each - a SODA priced as fresh lemons"
      ],

      // THE CELL-LEVEL FIX: the smallest change that makes this instance right.
      "surface_fix": {
        "what": "exclude the soda from the lemons commodity",
        "files": ["grocery/commodities.json"],
        "exact_change": "lemons.exclude += 'lemon[\\\\s-]*lime', '\\\\bmini\\\\s+cans?\\\\b'"
      },

      // WHY IT HAPPENED AT ALL, one level up. If this is empty the review is not finished.
      "root_cause": "the blocking food-class guard's beverage patterns are brand/word based, so a soda whose name carries no beverage token can win a produce cell at ANY fruit or vegetable commodity, not just lemons",

      // THE FIX FOR THAT. May be null ONLY when surface_fix IS the root fix, and say so.
      "root_fix": {
        "what": "add the missing tokens to category-excludes.json so audit-food-category hard-fails this class estate-wide",
        "files": ["grocery/category-excludes.json"],
        "exact_change": "beverage += mini cans / lemon-lime / starry / cola / seltzer"
      },

      // WHAT ELSE THE CHANGE TOUCHES, MEASURED, not guessed. This is the anti-regression core:
      // run the proposed regex over every product name in the newest comparison AND out\regular\*.json
      // AND out\sams|bakers|fareway captures, and report what gains or loses a match.
      "blast_radius": {
        "measured_by": "regex scan of 18,123 product names across comparison-2026-07-30 + out\\regular + out\\sams",
        "affected_now": 2,
        "names": ["Starry Mini Cans Lemon Lime, 7.5 fl. oz., 30 pk.", "Lulu Platanitios Lemon Plantain Chips, 2.5 oz., 30 pk."],
        "risk": "both are the wrong-product rows themselves; no legitimate produce name matches. Fresh Lemon / Fresh Lime verified NOT matched."
      },

      // HOW WE WILL KNOW IT WORKED, AND KEEPS WORKING. A fix with no reachable test does not ship
      // (see the 2026-07-29 lesson: two same-day fixes regressed because their self-test could not
      // reach the new code). Name the harness that already exists; invent a new one only if none fits.
      "proof": {
        "guard_or_fixture": "test-auditors.ps1 case (d2)",
        "must_fire_case": "frozen rows: the plantain-chips row on lemons and the mini-cans row on limes must make audit-food-category exit 2 AND name both classes",
        "clean_twin": "'Fresh Lemon' / 'Fresh Lime' rows must keep it at exit 0, or a token is too broad",
        "commands": ["powershell -File grocery\\audit-food-category.ps1", "powershell -File grocery\\test-auditors.ps1"]
      },

      "rollback": "revert the two json hunks; no data migration involved",

      // Hands off. Anything the developer must NOT change while implementing this item.
      "do_not_touch": ["the engine's each-branch pack division", "any guard threshold"],

      // What goes in triage-queue.json when this is done (1-2 lines, specific).
      "resolution_note": "Wrong product: Sam's Starry soda and Lulu plantain chips were pricing lemons/limes. Excluded at the commodity AND added to the food-class library so the guard catches the class. Board republished.",

      "status": "planned"   // developer updates: done | deviated | blocked | bounced
    }
  ],

  // The exact order the developer should ship in, including the gated chain. The reviewer owns the
  // sequence because it is the one who knows which changes interact.
  "ship_sequence": [
    "edit commodities.json + category-excludes.json",
    "compare-deals.ps1 -MinStores 1 -BakersFile <newest> -FarewayFile <newest>",
    "audit-food-category.ps1 (expect 0)",
    "audit-name-drift / prune-bad-links / generate-board-overrides / build-deals-page",
    "audit-match-soundness.ps1 -> review drops line by line -> -Accept",
    "guards.ps1 (MUST be 0) + audit-basis-reconcile + audit-pack-basis",
    "publish-deals-page.ps1",
    "test-auditors.ps1 (MUST be 0)",
    "commit + push, then verify one fixed cell on the live board"
  ],

  "open_questions_for_brad": []
}
```

## Rules that make the split worth having

1. **The reviewer never writes to the estate.** No edits, no publish, no commits, no `compare-deals` over
   the live `out\`. It measures with read-only scans, and if it truly needs a dry run it copies the minimal
   file set into the scratchpad and runs there. A reviewer that starts fixing is just a slower developer.
2. **The developer never re-diagnoses from scratch.** It implements the plan. When ground truth differs
   (a rebuilt board reveals a second wrong product, a store is walled, a concurrent session holds a file),
   it may deviate, but it records the deviation in the item and the same gates still apply.
3. **A new failure CLASS bounces back.** If implementing reveals a genuinely new class rather than a
   detail, the developer sets `status: "bounced"` with what it found, and the orchestrator runs ONE more
   reviewer round (round 2). Two rounds maximum, then whatever is left becomes `needs-brad`. This exists
   because discovery during implementation is normal here, not exceptional.
4. **Every item ends resolved, needs-brad, or blocked with a reason.** Silence is not a resolution.
