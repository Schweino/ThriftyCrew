# Backlog run, 2026-09-18 to 2026-09-19

The run log for working `design\BACKLOG-course-findings.md` end to end (Brad's brief of 2026-09-18). One line
per item: state, landed commit on origin/main, or the reason it stopped. **If this session is compacted or
restarted, read this file first and resume from the first item without a final state.**

Order: live-business risks first (I198, I205, I208+I209+I183, I195, I191), then every other `OPEN` and
`PARTLY DONE` item by the reversibility of its first rung (`2-WAY` before `1-WAY`; READ and MEASURE before
DOC before BUILD). `NEEDS A RULING` items are collected, not worked. Anything that reaches a reader or a
member, or cannot be undone, is prepared on a branch and marked READY FOR BRAD.

Orchestration branch: `claude/backlog-run-0919`. Each item lands through its own worktree and
`ops\push-main.ps1`; the landed hash is the one on origin/main.

## Items

| Item | State after this run | Landed / reason |
|---|---|---|
| I108 | NEEDS A RULING | lesson content: risk and insurance lesson shape, options written into the item |
| I109 | NEEDS A RULING | lesson content: emergency-fund lesson and cross-references to published Weeks 29-30 |
| I111 | NEEDS A RULING | lesson content: balance-sheet lesson and worksheet |
| I177 | NEEDS A RULING | rules text: does the lock order cover waits held under a lock |
| I205 | DONE | b986423a3 + 8f01557b2: literal ./ prefix stripped in pipeline-commit and bot-paths, MUST FIREs red under the old TrimStart, 0 of 8,563 tracked paths change verdict |
| I198 | DONE | 886796dff: Ghost POST no longer replayed on a timeout or 5xx, Friday send writes an invoking marker before it mails and refuses plus alerts on invoking-without-sent; 3 mutants killed |
| I199 | DONE | 886796dff: rules text names the headers that state idempotency |
| I195 | DONE | 3e5ee4b43: the 2026-09-11 lock cherry-picked onto main, harness re-run beside the live sidecar (6 of 6 double loads unlocked, 6 of 6 single locked), app_selftest MUST FIRE red with the lock broken; takes effect at the next sidecar restart |
| I183 | DONE | 4bb2295e9 + b262718d2: measured first (worst real name 15.1 ms over 42,753 names), then a 250 ms bound on every matcher regex, a timeout scored could-not-look and surfaced in the board health block and check-ad-cycles, 3-strike per-pattern breaker; 4 mutants red |
| I208 | DONE | 4bb2295e9: chicken-breast include atomic, 42,753 names resolve identically before and after, victim 7,354 ms to 13.6 ms |
| I209 | DONE | 4bb2295e9: the C# core catches the timeout; no RegexOptions.Compiled |
| I191 | NEEDS A RULING / READY FOR BRAD | built and landed as 32a035c34, then REVERTED on main because it moves 69 live prices and 26 cheapest-store verdicts; intact on branch claude/i191-add-norm-pid-fix. Found a live bug: the build's process id stored as the product id for Sam's and Fareway ad rows since 9c44c3a37 |
| I45 | DONE | 025584405 + f36e8fd4c: re-read over 12 TC tasks; the one scheduled data edge (07:00 ads -> 08:00 chain) held order on 14 of 14 ad days over 26 days; no capture-run fix warranted; probe committed as the reopen trigger |
| I105 | DONE | 224f874b5: read found no fix needed; all 20 Ghost update sites already fail loud on a 409 and ghost-lib never retries one; a re-read-and-resend branch would overwrite the other editor |
| I159 | DONE | 2dd5e949f: 14 load-bearing orderings over five libs, 10 cased, 1 declared-unused, 3 uncased; two mutated: ticket-order caught 4 of 6 by an existing case, flush counter a test aid; no case added, reasons recorded |
| I193 | NEEDS A RULING / READY FOR BRAD | 57b807ae1: read landed with a probe; peas are misfiled: two unlabelled 15 oz canned listings hold the two cheapest frozen-peas cells on the live board (0.0513/oz vs real frozen 0.0808+), reaching 28 recipes; fix changes a live price |
| I197 | PARTLY DONE | f092c8d57: 38 unbounded loops classified; 2 'capped' Ghost pagers could spin forever on a repeated next-page; Invoke-TcGhostPaged throws on a non-advancing page or past MaxPages, 3 mutants red. Remains: audit-ghost-drift.ps1:226 uncapped do/while (left while the board agent works grocery), media/reels/cdp.py:228 |
| NEW board wrong cells | READY FOR BRAD | branch claude/board-wrong-cells-0919 (ae4dba9c3): a global 'scent' exclusion with the 59 non-food commodities exempt moves 8 of 50,954 names off food rows and 1 of 3,189 cells (Family Fare strawberries: Dawn soap 0.1708 -> Fresh Strawberries 0.3119). The reader's board has been held by guards since 2026-09-12; a triage-developer lane in the main checkout has the unblocking fix staged (SAVE-cents parser, nut-beverage excludes, known-wrong for Dawn and Mochiko). Inbox file carried here for the final merge |
| I48 | NEEDS A RULING | 063b7ba13: re-measured free (frozen 20 cases still current, 16 of today's first 20 picks); the design assumes one candidate per call but production batches 10 (1 of 41 logged calls single); the next rung is paid Opus calls |
| I125 | DONE + READY FOR BRAD | 4d8192903: verdict CLOSE, 0 intraday moves over 28 morning-vs-afternoon produce pairs at Baker's (bar 24). Cleanup on branch claude/i125-probe-removal: Brad unregisters 'TC Produce Intraday Probe' then lands the branch the same day |
| I77 | PARTLY DONE | 63d9cbb8d (+ skills store eccd36b): one-hop recall arms measured over 14 cases against a 30-case bar written first: UNDERPOWERED (B vs A_n won 1 lost 1); re-run when cases reach 30 |
| I119 | DONE | ad85f1a7f: cold corpora measured against a bar written first: 0 malformed, 0 misdated, 0 rewritten history over 3,786 gold + 10,948 provenance + 617 db files; 23 of 281 hunter-gold rows name never-minted ids (recorded); no scheduled scrub built |
| NEW gate stderr | DONE | 7aeb653f0 + ef4ba9c74: audit-conclusion-currency classified every cited hash as a commit, so a cited BLOB (as measurement.md now asks) was dropped like a missing hash with only a stderr line; now commit/content/unresolved are counted, LIVE PATH case red under the old check. The 'origin' line is a deliberate pipeline-commit fixture, left. Inbox file run0919-gate-stderr.md filed DONE |
| I132 | DONE | f77b833e0: 107 tracked price files read: 0 of 4,284 non-success verdicts record their route, so none needs a second path; 3,697 were Family Fare throttling, gone since the 08-31 cap (0 of 125) |
| I129 | DONE | dc380c087: 9 of 132 checks (6.8%) are liveness (can fire when nothing happens) against a 10% bar written first: lopsided; report script + judged register committed. Follow-on ruling (which liveness checks to add) goes to the final report |
| I137 | NEEDS A RULING | 9b8c85073: 190 of 441 food-DB rows (43.1%) fillable with sodium+sugars+sat fat from the FDC API, bar 221 not met; sodium alone 218 of 220 FDC-cited rows. Ruling: store sodium / all three / decline / defer |
