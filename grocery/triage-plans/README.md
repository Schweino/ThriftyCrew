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

  // THE MEASUREMENT ITSELF, not just its summary. Sidecar file the reviewer writes next to the plan:
  // plan-<date>.routing.json = the frozen before/after routing of every affected name. The developer
  // DIFFS against this instead of re-deriving the corpus (on 2026-07-31 the reviewer routed 26,003 names
  // and the developer then rebuilt 25,939 of them to check the same contract). "Outside the contract"
  // becomes a set difference anyone can re-run instead of a claim to be reconstructed.
  // The sidecar MUST carry a positive_control and MUST cover ONE corpus. Both rules were bought on 2026-08-06:
  //   positive_control - two full 26,013-name simulations returned a confident ZERO because PowerShell
  //     variable names are case-insensitive, so `$b = Route $B $rules` destroyed the ruleset it was routing
  //     against. A zero-change result is indistinguishable from a simulation that never ran, and zero is the
  //     answer that ENDS an investigation ("this rule is a no-op, drop it"). So name a row you KNOW must
  //     reclassify and record that it did:
  //       "positive_control": { "name": "<a row that must move>", "expected": "<id>", "observed": "<id>" }
  //     validate-triage-plan.ps1 reads the artifact and rejects the plan if expected != observed.
  //   ONE corpus - the 08-06 artifact routed 79 files but built its aisle EXPOSURE list from a narrower set
  //     (the live FF sweep was appending, so it fell back to the previous day's file). The developer then
  //     paid to rediscover two Fareway rows the exposure list never covered. Every section reads the SAME
  //     file list, or the artifact names the skipped files explicitly so the gap is a lookup, not a hunt.
  "routing_artifact": "plan-2026-07-31.routing.json",
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
      //   superseded       - the same unresolved condition as another item in this plan; name which one.
      //                      (Five of 2026-07-31's fourteen alerts were this. They are not work.)
      //   needs-more-time  - hit the per-item effort ceiling; carries what was learned so far.
      // The last four are ONE-LINE items: classification, one evidence line, root_cause, resolution_note.
      // Do not spend blast radius, proof or rollback on "the Wednesday agent owns this".
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

      // THE FIX FOR THAT, i.e. what stops the CLASS coming back rather than this instance of it.
      // GATED SINCE 2026-09-03 (Brad's ruling): a code item must carry a root_fix, or carry
      // "root_fix_none_because": "<one line>" saying why the surface fix already IS the class fix.
      // root_cause was mandatory long before this and was being written well; what was missing is that
      // nothing checked the plan ACTED on it, so an item could name the class one level up, ship only
      // the instance fix, and pass clean. That is how a defect returns wearing a different commodity.
      // Measured the day the rule landed: the 2026-09-03 plan passed the OLD gate with 11 clean items
      // and 4 of them had no class fix at all - two were genuine deferrals nobody had written down
      // (the Family Fare 7-of-602 term budget, an 86-day rotation; and the feed checker's whole family
      // of "infer a push from a local artifact" call sites).
      "root_fix": {
        "what": "add the missing tokens to category-excludes.json so audit-food-category hard-fails this class estate-wide",
        "files": ["grocery/category-excludes.json"],
        "exact_change": "beverage += mini cans / lemon-lime / starry / cola / seltzer"
      },

      // WHAT ELSE THE CHANGE TOUCHES, MEASURED, not guessed. This is the anti-regression core:
      // run the proposed regex over every product name in the newest comparison AND out\regular\*.json
      // AND out\sams|bakers|fareway captures, and report what gains or loses a match.
      "blast_radius": {
        // MUST be "routing". A rule's impact is where products END UP after first-match-wins, never how
        // many names a regex hits. This estate made the proxy mistake TWICE on 2026-07-31: round 1 checked
        // each commodity's crown instead of each product's routing, and the taco-sauce measurement counted
        // 6 token matches when only 5 could route (hot-sauce claimed the sixth at a lower array index).
        // A match count both over-predicts (matches that change nothing) and under-predicts (second-order
        // re-landings). validate-triage-plan.ps1 rejects any other value.
        "measured_as": "routing",
        "measured_by": "before/after routing of 25,939 names across comparison-2026-07-30 + out\\regular + out\\sams + out\\bakers + out\\fareway",
        "affected_now": 2,
        "names": ["Starry Mini Cans Lemon Lime, 7.5 fl. oz., 30 pk.", "Lulu Platanitios Lemon Plantain Chips, 2.5 oz., 30 pk."],
        "risk": "both are the wrong-product rows themselves; no legitimate produce name matches. Fresh Lemon / Fresh Lime verified NOT matched.",

        // REQUIRED ON EVERY MATCHING-RULE CHANGE. Routing is itself a proxy, and this estate has now been
        // bitten at every layer of it. 2026-07-31 measured the CROWN and should have measured the ROUTE.
        // 2026-08-06 measured the route perfectly and a cell still moved 87% the wrong way: admitting ONE
        // goat-milk formula to baby-formula made a 1-row Sam's capture "cover" the commodity, which
        // discarded the 20-row capture behind it, and Sam's went $0.7704/oz -> $1.4445/oz. Both rows real,
        // both prices real, the crown unmoved, every guard green. Routing says where a NAME lands; it says
        // nothing about which ROW survives capture selection afterwards. THE OUTCOME IS THE CELL.
        // An empty array is a legitimate, checkable claim: "no cell moved". Omitting the field is not.
        "cell_effects": [
          { "commodity": "lemons", "store": "Sam's Club", "before": 0.5413, "after": 0.4200 }
        ]
      },

      // REQUIRED WHENEVER AN INCLUDE IS WIDENED. For each name the new token should admit, who claims it
      // today and at what array index. First-match-wins does not only hijack cells, it also silently
      // BLOCKS an intended admit: on 2026-07-31 taco-sauce (index 369) could never reach "Taco Bell Hot
      // Sauce" because hot-sauce (index 181) already matched it, so the widening needed a release exclude
      // on hot-sauce to work at all. Name the release excludes here or the developer discovers it mid-build.
      "claimed_by_earlier": [
        { "name": "Taco Bell Hot Sauce, 7.5 oz Bottle", "claimed_by": "hot-sauce", "index": 181, "release_needed": "hot-sauce.exclude += taco\\s+bell" }
      ],

      // WHAT THIS MEASUREMENT WAS TAKEN AGAINST, so a board that moved underneath is a checked branch and
      // not a judgment call. Four of fourteen items deviated on 2026-07-31 largely for this reason.
      "freshness": "measured against comparison-2026-07-30 (built 06:10) and the FF capture of 04:00; if the board has rebuilt since, re-run the routing diff before accepting - the FF sweep adds names every 3 hours",

      // HOW WE WILL KNOW IT WORKED, AND KEEPS WORKING. A fix with no reachable test does not ship
      // (see the 2026-07-29 lesson: two same-day fixes regressed because their self-test could not
      // reach the new code). Name the harness that already exists; invent a new one only if none fits.
      // must_fire_case AND clean_twin are BOTH gated since 2026-09-03. Naming a harness is not a proof:
      // a fixture that does not fire on the founding bug is decorative (five structurally dead guards
      // were found here in one sweep), and a must-fire with no twin passes by being too broad, which is
      // the "fix" that works by flagging everything.
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

      // Which publish this item rides. The board was rebuilt and republished THREE times on 2026-07-31
      // (round 1, round 2, a follow-up decision) at roughly eight minutes plus cache churn each. Items in
      // the same batch ship together on one publish; "next-round" means it can wait.
      "publish_batch": 1,

      "status": "planned",  // developer updates: done | deviated | blocked | bounced | superseded | needs-more-time

      // --- fields the DEVELOPER fills in, not the reviewer ---
      // A plan premise is a claim, not a fact. Two premises were false on 2026-07-31 (the Family Fare
      // cursor "skipping the wall", and a bounce claiming strawberries/milk had no sanity band - both do).
      // Re-check the premise against live data BEFORE acting and record the answer here, so a falsified
      // premise is visible in the artifact instead of buried in a report.
      "premise_verified": null,   // true | false + what you checked
      "deviation": null,          // what ground truth said, and what you did instead
      "shipped_commit": null
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
5. **A bounce carries a measurement, not an observation.** Round 1's bounce on 2026-07-31 was directionally
   right and factually wrong (it claimed two commodities had no sanity band; both do, and the engine had
   already stamped OUT-OF-BAND on the exact rows). If the bounce had been required to show the measurement,
   it would have died inside the developer instead of costing a whole review round.
6. **Effort ceiling per item.** If one item exceeds the ceiling the dispatch names, park it as
   `needs-more-time` with what was learned and move on. One item must not eat the budget for thirteen others.

## The gate

`grocery/validate-triage-plan.ps1 -Plan <path> -OpenIds <ids>` is the handoff gate and it is deterministic:
exit 0 hand it over, 2 incomplete (it prints exactly what is missing), 3 BLIND (no plan, unparseable, or
zero items). It has its own `-SelfTest` with frozen good and bad fixtures, including must-fire cases for
the two mistakes this estate actually made: a blast radius `measured_as` anything other than `routing`, and
a widened include with no `claimed_by_earlier`. The orchestrator runs it instead of eyeballing the plan,
because an unversioned check nobody can re-run is a habit, not a gate.

## Housekeeping

Plans accumulate one per day and are rotated monthly by `run-daily-local.ps1` into `grocery/logs-archive/`
alongside the pipeline logs. Git history keeps the content either way.
