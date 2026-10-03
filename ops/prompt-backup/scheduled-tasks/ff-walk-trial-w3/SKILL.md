---
name: ff-walk-trial-w3
description: One paced window of the Family Fare catalog-walk trial (R7.2), then a re-score; changes nothing in the repo.
---

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