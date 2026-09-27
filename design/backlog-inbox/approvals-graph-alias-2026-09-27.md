# approvals-apply lane, 2026-09-27

## an accepted graph alias cannot apply because stage 1 names the commodity by a slug of its LABEL

`NEEDS A RULING` `2-WAY` `RUNG1 RULING`

**The ask, in plain words, is
`design/ready-for-brad/Q-2026-09-27-graph-alias-target-resolution.md`.** This entry is the technical
record behind it: the issue, why it matters and the recommendation are on that page, in the shape Brad
asked for on 2026-09-27, and everything below is the evidence.

**Source.** Brad answered `Accept` on the approvals page for graph alias proposal
`lp:15b86381b00f7df97f95` (`dog-food-dry <- dry\s+doog\s+food`, inbox id
`graph:lp:15b86381b00f7df97f95`) on 2026-09-27. The verdict is recorded through
`graph/learning/stage2_review.py --ingest` in this lane's commit, so the ruling is durable. It cannot
reach the graph, because `resolve_target` returns `None` for `dog-food-dry`: the commodity this estate
holds is `commodity:staple:dog-food`, whose canonical name is `Dog Food (dry)`. Stage 1 sees the human
LABEL and answers with a slug of that label; the ladder tries the id verbatim, then
`commodity:staple:<target>`, then `commodity:recipe:<target>`, then the canonical name matched
VERBATIM, which a slug never is.

**What the alias itself does, since the approvals item said no blast radius existed for it.** Run at
ruling time through `graph/learning/alias_blast_radius.py --pattern 'dry\s+doog\s+food' --target
commodity:staple:dog-food` (the ad-hoc road, which writes no report and so cannot truncate the tracked
one): exit 0, `kill=false`, no warn reasons, and of 1 total hit over the whole captured-name corpus,
1 `intended_capture` (`Premium Dry Doog Food Each`, 26 rows), 0 `absorbs_review`, 0 `already_matched`,
0 `cross_commodity`, 0 `known_wrong_hit`, 0 `rejected_hit`, 0 `blocked_by_rules`. Nothing argues
against the accept. The gap is the target id, not the pattern.

**Measured, and the reason this is a ruling and not a fix.** The obvious repair is one more rung on
`resolve_target`: slugify each `Commodity` node's `canonical_name` and match the target against that,
refusing a slug that two commodities share. Measured before proposing it, one row per
`learning_proposals` row left-joined to its `approved_patches` row, a scratch probe run on 2026-09-27
against a `Connection.backup()` snapshot of `C:\Codex\ThriftyCrew\graph\sqlite\graph.db`
(453,259,264 bytes, 712 `Commodity` nodes, 84,466 aliases), exit 0:

- 348 rows in total.
- 268 of 348 resolve under the ladder as it stands.
- 80 of 348 do not resolve today.
- 72 of those 80 rows, being 68 distinct proposals over 16 distinct declared target ids and 16
  distinct commodities, would newly resolve under the slug-of-label rung. 0 slugs matched two or more
  commodities, so no case was refused for ambiguity.
- Of those 68 proposals, 51 are still `proposed`, 15 are `rejected`, and 2 are `accepted` and parked
  (both `jasmine-rice-dry`, which would newly resolve to `commodity:recipe:jasmine-rice`).
- The 16 targets: `artichoke-hearts-canned-jarred`, `beets-fresh`, `black-pepper-ground`,
  `brown-gravy-mix-dry-packet`, `cajun-creole-seasoning`, `canned-diced-tomatoes`,
  `canned-pasta-ravioli-spaghettios`, `dish-soap-liquid`, `dishwasher-detergent-pacs`, `dog-food-dry`,
  `frozen-chicken-nuggets`, `frozen-cut-green-beans`, `iced-tea-bottled-gallon`, `jasmine-rice-dry`,
  `large-eggs-dozen`, `popsicles-ice-pops`. Two of them, `black-pepper-ground` and `dish-soap-liquid`,
  are the very ids `stage2_review.py`'s own header names as the 2026-08-20 parked patches.

So the rung is not a one-alias change. It is a change of resolution regime over 68 proposals, and
`stage2_review.py`'s header is explicit that widening the ladder applies every parked pre-approved
patch at once with no fresh eyes, which is why `--requeue-stuck` exists and must run first. This lane
was applying one ruling Brad gave, so it did not make that change and did not run `--requeue-stuck`,
which would have demoted three other sessions' parked approvals.

**Nothing silently reverses Brad's accept in the meantime.** `graph/pipeline/nightly.ps1` runs only
`--emit-packet`; `--ingest`, `--apply` and `--requeue-stuck` are hand steps, so the proposal stays
`accepted` until a person runs one. The row that would be lost is the one `--requeue-stuck` demotes,
and only if somebody runs it before the ladder resolves this target.

**What is owed.** A ruling on whether `resolve_target` gains the slug-of-canonical-name rung. If yes,
the order is fixed by the header: `--requeue-stuck` first, so the three parked approvals go back to
review rather than applying under a ladder nobody reviewed them against, then the rung with a fixture
carrying a must-fire (`dog-food-dry` resolves to `commodity:staple:dog-food`), a must-not-fire (a slug
two commodities share resolves to nothing) and a clean twin (an id that already resolved still
resolves to the same node), then `--apply` with its gold-set shadow gate untouched. If no, then
`lp:15b86381b00f7df97f95` and the 67 others need their targets fixed at the source, in stage 1's
prompt, so the loop stops minting targets the graph cannot name.

**Harness.** Described, not committed: the probe is 40 lines and its whole rule is stated above.
The subjects it read are `graph/learning/stage2_review.py` at blob
`4ea4aa43723764887c25956e958343e20bb06372` and `graph/learning/alias_blast_radius.py` at blob
`f6a3933b5be6e00d07ee0b9da04cf88b9312dbd0`. A blast radius or a rung change that moves either makes
the counts above unqualified until somebody re-runs them.
