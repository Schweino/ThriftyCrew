# Registering verify-board-sample (backlog I232)

Your ruling of 2026-09-19: every 14 days a scheduled agent with a browser checks a 100-cell sample of the board
against the stores' own pages and records the verdicts. The prompt is ready and the code it calls is on main
(`grocery\record-sample-verdict.ps1` gained `-Due`, `-CompareLast -Alert`, the words `match` and
`could-not-look`, and the rule that a match with no price read off the page is recorded as could-not-look).
Nothing is registered. Three actions, in this order.

**1. Register it as a Claude Desktop scheduled task** (not a Windows task: only a Desktop session has the
claude-in-chrome extension, and a headless `claude -p` has no browser at all). In a Claude Desktop session, ask
Claude to call `create_scheduled_task` with exactly:

    taskId:          verify-board-sample
    title:           Board verification sample (every 14 days)
    cronExpression:  30 10 * * 0
    description:     the `description:` line of verify-board-sample.SKILL.md
    prompt:          everything in verify-board-sample.SKILL.md BELOW the closing `---` of its front matter

`30 10 * * 0` is Sundays at 10:30 local, after the 08:00 chain and the 09:45 triage. Cron cannot say "every 14
days", so the trigger is weekly and the prompt's first step (`record-sample-verdict.ps1 -Due`) stops the run
unless 13 or more days have passed since the newest whole-board run that verified at least 30 cells. On time
that lands every 14 days; a missed or browserless week is caught up the next Sunday. The task runs only while
the Desktop app is open (a due run fires at the next launch), and it needs Chrome running with the extension
connected, but not you at the keyboard. Then press **Run now** once, so the browser tool approvals are stored
and a scheduled run cannot stall on a permission prompt. Today `-Due` reads `due=yes` (newest verified board
2026-08-15, recorded 33.8 days ago), so that first run does the real work. The last measured rate it will be
compared against is the 2026-08-15 board: 18.2%, 95% CI 9.5% to 32.2%, 20 defects in 100 verified.

**2. Back the prompt up** (from the main checkout, the same step every scheduled task takes;
`audit-prompt-backup` fails every push while a live task has no mirror):

    powershell -NoProfile -File ops\audit-prompt-backup.ps1 -Adopt 'scheduled-task|verify-board-sample'

commit `ops\prompt-backup\scheduled-tasks\verify-board-sample\SKILL.md`, and delete this file and verify-board-sample.SKILL.md.
The old `grocery-accuracy-sample` task (disabled 2026-08-22) is the same job with an older prompt: once this
one is registered, deleting that one leaves one prompt for one job.

**3. After the first run has RECORDED a sample** (and not before: `grocery\out\verification-history.json` was
last written for the 2026-08-15 board, so the row would page the moment it lands), add this row to
`output_files` in `grocery\expected-automations.json`:

    {
      "path": "grocery/out/verification-history.json",
      "max_age_hours": 408,
      "why": "the 14-day out-of-band verification (Claude Desktop task verify-board-sample, Brad's ruling 2026-09-19, backlog I232). Only record-sample-verdict.ps1 writes this file, once per verified sample, so its mtime is the verification's liveness. 408h = 17 days: the 14-day cadence plus the ~1 day before the main checkout pulls the landed file, plus 2 days' slack. WHEN THE PRODUCER STOPS (task unregistered or disabled, Desktop app closed, Chrome not connected, which records nothing by design) the file only ages, and this row pages on day 18; nothing else watches a Claude Desktop task. Its blind spot: a run that records but verifies fewer than 30 cells refreshes the mtime while quoting no rate; record-sample-verdict.ps1 -Due still reads due=yes then, so the next weekly trigger retries."
    }

A Desktop scheduled task is not a Windows task, so the `windows_tasks` list cannot see it; the file it writes is
the only thing the heartbeat can watch. The row is watched from the 10:30 watchdog like every other.
