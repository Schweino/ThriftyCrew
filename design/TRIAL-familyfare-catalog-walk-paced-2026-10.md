# TRIAL: Family Fare catalog walk, the paced re-run (step 3b, R7.2)

**Status: PREPARED 2026-10-03, NOT RUN.** Brad ruled R7.2 on 2026-10-03 ("Run the trial (Recommended)",
`design/PLAN-weekly-root-families-2026-10-02.md` Phase 7). This trial answers the two criteria the September trial left
at COULD NOT VERIFY. Then Brad rules build or not. The rubric below was written before any request was sent (ms-03), and
no number in it may change after the run starts.

Nothing in the pipeline changes. The trial writes only to a run folder outside every checkout. It never touches a board,
`grocery\out`, the capture cursor, the term ledger or `sale-windows.json`. The quarterly rotation ruling is untouched.

## No browser is needed (a correction to the ruling note)

`design/ready-for-brad/weekly-root-families-phase-7.md` says the trial "needs a browser session". The code does not
support that.
- Family Fare capture is plain token-less HTTP from PowerShell: `Get-FreshopItems` in `grocery/pull-regular-familyfare.ps1`,
  `Invoke-RestMethod` with `User-Agent: Mozilla/5.0`.
- The September trial ran the same way, with `Invoke-WebRequest -UseBasicParsing`.

So the instrument is a PowerShell script, and it runs the same in a headless dispatch or an attended session. It is
still a scheduled run, because its windows have to fall at night, clear of the capture schedule.

## What is open

The September rubric, verbatim (`design/TRIAL-familyfare-catalog-walk-2026-09-10.md`, carried into
`PLAN-zero-alert-days-remainder-2026-09-24.md` section 2, 3b): "Rubric: complete NOT MET; follow-up search COULD NOT
VERIFY; covers the rotation COULD NOT VERIFY. The lower bound: 2,339 of 5,395 everyday rows found in the 35.6%."

The step 3 bar, verbatim: "a verdict per store backed by a captured network request, or a recorded wall; a CAPTCHA is a
hard stop and a verdict, never a bypass." There is one store here, and every verdict below names the raw response files
it rests on.

What September established, and this trial builds on:
- Only `skip=` pages a department browse. `page=` and `offset=` return page 1 forever, with a 200 and a correct total.
- A page holds at most 100 rows. `limit=200` and `limit=500` are silently clamped.
- At a 2.5 s gap, one window held 66 distinct pages. Request 67 got HTTP 400 with body `{"error_code":429}`.
- Freshop has also answered its throttle as a 200 with an empty `items` array (memory `fail-open-reads-as-empty`,
  2026-08-15).

## The rubric, in measurable units

Each bar is compared as integers (`found*100 >= bar*denominator`), so a case exactly at the bar is exact. Every bar is
the first plausible value, with no sweep (og-14). The trial runs once.

| Criterion | MET when | NOT MET when | COULD NOT VERIFY when |
|---|---|---|---|
| **C1. The walk is complete** (a precondition, re-measured) | unique product ids read >= **99%** of the largest `total` any page reported | under 99% | no page answered with a total |
| **C2. A follow-up search works** | in the same window, after a walk of **30 distinct pages**, **20 of 20** rotation searches answer HTTP 200 **with at least one row** | any of the 20 is refused (a 4xx, including the 400 carrying 429) | no window finished its 30-page walk, or a search came back an empty 200, or a server error or cap ended the window first |
| **C3. It covers what the rotation buys** | everyday rows found in the walk by product id >= **95%** of everyday rows that carry a product id | under 95% **and** C1 is MET | under 95% and C1 is not MET (the count is then a lower bound, reported as one) |

**Why these units.**
- **C2's 20** is the production per-window ceiling (`window_ceiling: 20` on `family-fare-regular-2026-10-02.json`).
  So "the search still works" means the rotation's whole window of buying survives the walk.
- **C2's 30 pages** is the depth a lane could walk every window. That is under half of September's measured 66, and
  186 pages over the three daily windows is about two days.
- **The 20 search terms** are spread evenly over the `found_by_term` terms of the newest everyday file. These terms are
  known to return products, so an empty answer is suspicious rather than expected. That is why an empty 200 is never
  counted as answered.
- **C1's 99%** allows for products added or removed during a walk that spans hours.
- **C3's 95%** allows for rows carried for up to the 90-day quarter whose product the store has since dropped.
- **C3's population** is product-id rows (3,835 of 5,602 on 2026-10-02). The `name|size` key is not identity, as
  September showed: 6,600 ids mapped to 6,586 keys. Rows without an id are matched on `name|size` and reported, but
  never barred.

**Reported, not barred:**
- **Is the allowance shared?** Every later window ends with one search (`milk gallon`, September's term). After a browse
  refusal, an answered search means browse does not spend the search allowance, and a refused one means it does. This
  decides whether a lane could walk deeper than 30 pages a window.
- **Ordering stability.** Every window re-reads page 1, and the scorer counts the windows whose page 1 matches the
  first.
- **Per-term coverage.** Terms with at least one row in the walk, and terms with every row in it.
- **The morning after.** Did the first Family Fare window after the trial buy its terms (step 6 below)?

## Pacing and stop rules

| Setting | Value | Why |
|---|---|---|
| Gap between requests | 5 s from the end of one to the start of the next, so at most 12 a minute | Twice September's 2.5 s. Production budgets requests per window, not pace, so a slower pace costs nothing and may tell the two apart |
| Window A | page 1, then 29 more distinct pages, then the 20 searches: 50 requests, about 5 minutes | C2 |
| Each later window | page 1 (the ordering probe), then up to 100 new pages, then 1 search: at most 102 requests, about 10 minutes | C1 and C3, plus the shared-allowance reading |
| Gap between windows | at least 45 minutes from one window's end to the next one's start | Hourly fires at :05 leave about 50 minutes |
| Trial hours | a window may start from 19:00 to 04:30 | `TC Grocery Ad Pulls 0700`, `Daily Capture 0800`, `Capture Watchdog 1030` and `Browser Slot Close 1415` run from 07:00 to 17:15. That leaves at least 2.5 hours of recovery before the 07:00 window |
| Caps | 6 windows, 450 requests | At September's 66 pages a window, the 186 pages take window A plus 3 to 4 later windows, about 300 requests |
| Expected length | 4 or 5 windows, 20:05 to about 00:15 | |

**Stop rules, enforced in the script:**
- **The first 4xx ends the window.** This includes the 400 carrying `error_code 429`. A refused page is not counted, and
  the next window resumes at that page.
- **A page that brings no new ids ends the window as `no-progress`.** This covers an empty 200, or an ignored `skip=`
  repeating page 1. It is not counted as a page.
- **A 5xx or no response gets one retry after 30 s.** A second failure ends the window.
- **A WALL ENDS THE TRIAL.** A wall is any 403, or any body that is not the API's JSON: an HTML page, a CAPTCHA, a
  challenge, "verify you are human". Every later window is refused, and the wall is recorded as the verdict with its
  raw file. It is never retried, never opened in a browser, and never routed around.
- **A window is skipped and sends nothing** in any of these cases:
  - another Freshop caller is running (`pull-regular-familyfare`, `familyfare-sweep`, `probe-ingredient`,
    `hunt-daemon` or `capture-run`);
  - `Global\tc-capture-run` is held, so the trial and a capture run can never overlap (lock order 0, zero wait);
  - it is outside the trial hours;
  - it is too soon after the last window;
  - a cap is reached;
  - the trial is complete.

## What is captured, and where

The run folder is `%LOCALAPPDATA%\ThriftyCrew\trial-ff-walk\paced-2026-10\`. It is outside every checkout, and the script
refuses a run folder inside any git work tree.
- `requests.jsonl` has one row per request, retries included. Each row holds: window, kind, phase, `skip` or term, URL,
  time, ms, status, `error_code`, class (`ok`, `throttle`, `client-error`, `server-error`, `no-response`, `wall`), rows,
  new ids, total, and the raw file.
- `raw\<window>-<seq>.json` (or `.txt` for a non-JSON body) is every response body, verbatim. These are the evidence.
- `state.json` holds the walk position, the windows run, the 20 search terms chosen, and any hard stop.
- `verdict.json` is the scorer's output. It holds one block per criterion with its numbers and evidence files, the
  everyday file it scored against with its SHA-256, and the harness blob.

The URLs carry no token or credential. Family Fare's `app_key=family_fare` is a public named key.

## The steps

1. Land `grocery/trial-ff-catalog-walk.ps1` on main. Its `-SelfTest` runs on every push.
2. The lead registers the scheduled session below as ONE task that fires six times on one night: 20:05, 21:05, 22:05,
   23:05, 00:05 and 01:05. Each fire runs at most one window. A fire after the trial is complete, capped or walled
   sends nothing and only re-scores.
3. Each fire runs `-Window -Live`, then `-Score`.
4. The fire after the last window reports the final verdict. `verdict.json` is overwritten each time, so the last one
   stands.
5. The lead or an orchestrator copies the five verdict lines and the window table from `state.json` into **Results**
   below, and records the harness blob from `verdict.json`.
6. **The morning after:** after 07:05, check that the Family Fare entry in `grocery\out\capture-cursor-log.jsonl` dated
   that day advanced (`to` > `from`). If it did not, suspect the trial first, as September said.
7. Brad rules build or not on those verdicts.

## The scheduled-session prompt

Register this verbatim, after step 1 has landed. Any surface with a PowerShell tool works, because no browser tool is
used.

```
You are running ONE window of the paced Family Fare catalog-walk trial (Brad's ruling R7.2;
design/TRIAL-familyfare-catalog-walk-paced-2026-10.md in C:\Codex\ThriftyCrew). You change nothing in the repo:
no edit, no commit, no push. The script writes only to its run folder under %LOCALAPPDATA%.

1. Run the next window, sending output to a file and reading the EXIT CODE before anything else:
     powershell -NoProfile -File C:\Codex\ThriftyCrew\grocery\trial-ff-catalog-walk.ps1 -Window -Live -RunDir "$env:LOCALAPPDATA\ThriftyCrew\trial-ff-walk\paced-2026-10" > "$env:TEMP\ffw-window.txt"
   Then read the last line of that file. It starts FF-WALK-TRIAL-COMPLETE.
   - Exit 0 and "skipped: ...": no window was due or allowed. Report the reason.
   - Exit 0 and "window=...": report that summary line as it stands.
   - Exit 2: a WALL (a CAPTCHA, a challenge page or a 403) stopped the trial for good. Do NOT retry. Do NOT open
     shopfamilyfare.com or the Freshop API in any browser. Do NOT try another route, header or address. Report the
     window and the raw file named under hard_stop in state.json. A wall is a verdict, never an obstacle.
   - Exit 3: report the line verbatim and stop.
2. Then, whatever step 1 said, score what has been captured so far (this sends nothing):
     powershell -NoProfile -File C:\Codex\ThriftyCrew\grocery\trial-ff-catalog-walk.ps1 -Score -RunDir "$env:LOCALAPPDATA\ThriftyCrew\trial-ff-walk\paced-2026-10" > "$env:TEMP\ffw-score.txt"
   Read its exit code, then report its lines (C1, C2, later windows, C3, verdict path, FF-WALK-SCORE-COMPLETE). Exit 3
   before the first window has run is expected.
3. Never run -Window more than once in a fire. Never send any other request to Freshop or shopfamilyfare.com. Never
   change the pacing, the caps or the stop rules, and never solve or bypass a CAPTCHA. If something looks wrong, report
   it and stop.
Report in plain words: which window ran (or why none did), its outcome, and the current verdict per criterion with
its numbers.
```

**A Windows scheduled task instead:** it can run the same two commands. A new TC task needs the headless conhost wrapper
(memory `scheduled-tasks-run-under-headless-conhost`), so the Claude session is the cheaper registration.

## Harness

- **Harness:** `grocery/trial-ff-catalog-walk.ps1`, written 2026-10-03, with a 34-case hermetic `-SelfTest`. It holds
  both the window runner and the scorer, so the instrument and the judge are one versioned file. Its blob at scoring
  time is written into `verdict.json` as `harness_blob`. Results copied here must quote that blob, never a local commit
  hash (ms-07).
- **Runtime:** Windows PowerShell 5.1, `Invoke-WebRequest -UseBasicParsing`. This is the September request shape.
- **Fields:** the builder's `$FIELDS_RICH`, verbatim: `id,name,size,price,base_price,unit_price,canonical_url`.
- **Browse base:** `https://api.freshop.ncrcloud.com/1/products?app_key=family_fare&store_id=6401&department_id=22585550&department_id_cascade=true&limit=100&skip=N`.
  This is September's root department, and its `total` is re-read, never assumed.

## Results

Not run yet. Each criterion gets its verdict line from `verdict.json`, the window table from `state.json`, the harness
blob, and the morning-after check.

## Knowledge consulted

- Searched "paced trial rate limit Freshop walk" (knowledge-search --estate). Used:
  - memory `fail-open-reads-as-empty`: Freshop's throttle has come back as a 200 with empty `items`. That became the
    `no-progress` stop and the rule that an empty search is never counted as answered.
  - `grocery/ff-price-lib.ps1` section 3, "A FRESHOP PAGE IS ONLY PROGRESS IF IT BRINGS NEW IDS": the same rule, which
    the walk follows.
  - memory `grocery-method-familyfare`: the public `app_key` and store 6401.
- From the brief: memory `attended-chrome-capture-obstacles` and `capture-sink-binds-localhost-not-127`. Neither
  applies, because no browser or sink is used.
- From the brief: memory `chrome-is-always-available`. It says a headless dispatch has no browser tools, which this
  trial does not need.
- From the brief: `.claude/rules/grocery.md` gr-17, the four causes of an empty result. The empty-200 handling follows
  it, and a page is judged by its new ids, never by sleeping and hoping.
- From the brief: `.claude/rules/measurement.md` ms-01 (denominators on every verdict), ms-03 (the bars above, written
  before the run) and ms-07 (the harness blob).
- `.claude/rules/ops-and-gates.md`:
  - og-06: at-bar and past-bar cases for the C1, C3 and gap bars, built from integers;
  - og-27: the capture-run mutex is lock 0, taken with zero wait;
  - og-36: no wall-clock bar in the self-test, because sleep and clock are seams.
