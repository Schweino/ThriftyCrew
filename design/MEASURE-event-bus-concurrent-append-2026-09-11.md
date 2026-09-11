# Does the event bus lose events when several processes write at once

**Question.** `lib\event-bus.ps1`'s `Write-TcEvent` appends to the bus through
`New-Object IO.StreamWriter($p, $true, ...)`, which opens the file with a share that denies other writers, and
it swallows every error and returns `$false`. A bare `Add-Content` with the same kind of open landed 13 of 200
lines with 2 processes and 5 of 1,200 with 4 (`lib\append-line.ps1` header). `Write-TcEvent` was never
measured. Its producers include `ops\run-gates.ps1` (one per push, and several sessions push from this box),
`lib\ledger-lock.ps1` and `meal-prep\pipeline\source-domains.ps1` refusals (written exactly when writers are
contending), so concurrent producers are plausible.

## The acceptance bar (written 2026-09-11, BEFORE any trial ran)

It was committed on its own, before the first trial, as *"Event bus concurrency: the acceptance bar, written
before any trial ran"*, author date 2026-09-11T14:06:06-05:00. Cite it by that subject, not by hash: it was made
as `e7c21e87a` and rebased twice before it reached main, and the run-2 rows record that first hash in
`base_commit`. `git log --grep="the acceptance bar, written before any trial ran"` finds it.

**Design.** N child processes each dot-source a copy of `lib\event-bus.ps1` and call the real `Write-TcEvent`
E times against one temp bus passed through `-Path`, never the live bus. One row per trial per arm.

- Cells: W = 1 (the control), 2, 4 and 8 writer processes; E = 200 events per writer; 5 trials per cell per
  arm. The event is ~250 characters of JSON.
- **Overlap is proven by rendezvous, never by a clock.** Every child waits until all W children are ready
  before its first write, and waits until all W children have MADE their first write before its LAST write.
  When every child saw all W first-write markers, every child was inside its write loop at the instant the
  last one began writing, so the writing windows overlapped. No wall-clock bar decides anything; elapsed time
  is recorded as information only.
- Landed is counted from the bus: lines that parse as JSON, carry `kind = measure`, and are DISTINCT on
  (tag, i). Unparseable lines and duplicates are counted separately.
- Arms: `old` is `lib\event-bus.ps1` as committed at the base commit; `new` is the fix, when there is one. In
  the comparison run the arms ALTERNATE trial by trial, so a change in machine load cannot fall on one arm.

**A trial is VALID** when all W children reported and, for W of 2 or more, every child saw all W first-write
markers. An invalid trial is BLIND and counts for neither verdict.

**The harness check.** The W = 1 control must land 200 of 200 in every trial of every arm. If it does not, the
whole run is BLIND and no verdict below is drawn.

**Verdict on the old code.** `Write-TcEvent` LOSES EVENTS UNDER CONCURRENCY if at least one valid trial with
W of 2 or more lands fewer distinct events than it sent. It DOES NOT LOSE THEM AT THIS SCALE only if every
valid W >= 2 trial lands sent of sent AND at least 10 of the 15 W >= 2 trials are valid. That second verdict
would prove nothing about wider contention.

**The fix is accepted** only if all of these hold in the alternated run:

1. The new arm lands sent of sent in EVERY valid trial of every cell: zero lost over the whole run's total,
   zero duplicates, zero unparseable lines.
2. In every new-arm trial `Write-TcEvent` returned `$true` exactly `sent` times and never threw.
3. At least 12 of the 15 new-arm W >= 2 trials are valid.
4. The old arm, in the SAME alternated run, still loses in at least one valid trial. If it does not, the run
   did not reproduce the defect and the comparison says nothing about the fix.

**The boolean must be honest in both arms.** In every trial the number of `$true` returns must equal the
number of events that landed. A `$true` whose line is absent would be a separate and worse defect, reported
whatever else happens.

## Results

**Harness:** `bus-harness.ps1`, a scratch script reproduced in full at the end of this file (md5
`5ad6f9f45f7ce7378aa51a392306efeb`). It is recorded here rather than committed as a `.ps1`, because a script
under `design\` would be discovered by every tree walk and census in the gate.
**Code it ran against:** the old arm is `lib\event-bus.ps1` blob `1128546c`, byte-identical to base commit
`8253ded82` (run 1) and to the bar commit above, then `e7c21e87a` (run 2). The new arm is md5
`b11149f3e9bb71ef71628296fada6d27`: the committed fix before the run-2 numbers were written into its header
comment, which is the only difference. `lib\append-line.ps1` is blob `54a2fa74`, identical to `origin/main`.
**Rows:** `design\MEASURE-event-bus-concurrent-append-2026-09-11.jsonl`, one row per trial per arm, 60 rows.
Every total below is derived from that file.
**Machine:** 32 logical cores, Windows 11, PowerShell 5.1, shared with other sessions.

**Every launch, in order, including the ones that produced nothing:**

1. The first launch bound `-Cells 1,2,4,8` as the single number **1248** under `powershell -File`: the
   argument reaches an `[int[]]` parameter as one string, and the conversion reads the commas as thousands
   separators. It started 1,168 child processes before it was killed about a minute in. It wrote no rows and
   counts for nothing. The harness now takes the cells as a string, splits them itself, and refuses more than
   16 writers.
2. The second launch refused to start: the split array was assigned back to the `[string]` parameter and
   coerced into `"1 2 4 8"`. No child ran.
3. Run 1, the old code alone.
4. Run 2, old and new alternated. No other variant of the fix was measured.

### Run 1: the old code alone

| writers | landed of sent | lost | trials that lost | lost per trial |
|---:|---:|---:|---:|---:|
| 1 | 1,000 of 1,000 | 0.0% | 0 of 5 | 0 |
| 2 | 1,878 of 2,000 | 6.1% | 5 of 5 | 19 to 33 |
| 4 | 3,205 of 4,000 | 19.9% | 5 of 5 | 150 to 172 |
| 8 | 4,792 of 8,000 | 40.1% | 5 of 5 | 600 to 678 |

20 of 20 trials valid. 0 unparseable lines, 0 duplicates, 0 throws. Every lost event returned `$false` (122,
795 and 3,208), and in 20 of 20 trials the `$true` count equals the landed count.

**Verdict: `Write-TcEvent` LOSES EVENTS UNDER CONCURRENCY.** 15 of 15 valid multi-writer trials lost events,
and the control landed 1,000 of 1,000. Nobody could have seen it: every producer discards the boolean with
`$null =`.

### Run 2: old and new alternated trial by trial

| writers | old: landed of sent | old: trials that lost | new: landed of sent | new: trials that lost |
|---:|---:|---:|---:|---:|
| 1 | 1,000 of 1,000 | 0 of 5 | 1,000 of 1,000 | 0 of 5 |
| 2 | 1,885 of 2,000 (5.8% lost, 16 to 30 a trial) | 5 of 5 | 2,000 of 2,000 | 0 of 5 |
| 4 | 3,186 of 4,000 (20.4% lost, 148 to 182 a trial) | 5 of 5 | 4,000 of 4,000 | 0 of 5 |
| 8 | 4,819 of 8,000 (39.8% lost, 601 to 693 a trial) | 5 of 5 | 8,000 of 8,000 | 0 of 5 |

40 of 40 trials valid. 0 unparseable lines, 0 duplicates, 0 throws in either arm.

**Against the bar:**

1. New arm lands sent of sent in every valid trial: **15,000 of 15,000 over 20 of 20 trials**, 0 duplicates, 0
   unparseable. MET.
2. `$true` exactly `sent` times, never threw: 15,000 `$true`, 0 `$false`, 0 throws. MET.
3. At least 12 of 15 new-arm multi-writer trials valid: **15 of 15**. MET.
4. The old arm still loses in the same run: **15 of 15** multi-writer trials. MET.
5. The boolean is honest in both arms: **40 of 40** trials. MET.

**The fix is accepted.** One variant of the fix was measured, so this is not the survivor of a sweep.

**What this does not show.** Nothing about more than 8 writers, a network share, or a writer-denying handle
held on the bus for longer than `Add-TcLine`'s retry budget (about 7.3 s). That budget is also a new cost:
where the StreamWriter returned `$false` at once, a producer can now wait that long before it gets its
`$false`. `Read-TcEvents` is one such handle for the length of one read, because `[IO.File]::ReadAllLines`
shares Read only. It was not changed, and no trial ran a reader against the writers.

## The self-test and its mutation probe

`ops\audit-event-bus.ps1 -SelfTest` gained three cases:

- **MUST FIRE**: 4 processes x 200 events at once land all 800, each call returning `$true`, with the
  rendezvous above proving the overlap. A run that did not overlap fails the case and says so.
- **MUST FIRE**: an event that could not land returns `$false`, never `$true`.
- **MUST NOT FIRE**: a copy of `event-bus.ps1` with no `append-line.ps1` beside it loads and writes without a
  throw and returns `$false`. The appender is a dependency now, and the bus must still never break its
  producer.

Mutation probe, 2026-09-11. Each mutant is one compiling change to `lib\event-bus.ps1`, run from a temp
mirror. The four originals were byte-identical by md5 before and after:

| mutant | self-test | what caught it |
|---|---|---|
| none (control) | exit 0, green | - |
| M1 append back through a StreamWriter (the founding bug) | exit 1, killed | concurrency case: 635 of 800 landed, 165 `$false` |
| M2 append through a bare `Add-Content` | exit 1, killed | concurrency case: 22 of 800 landed, 778 `$false` |
| M3 the catch returns `$true` | exit 1, killed | the `$false` case and the missing-appender case |
| M4 the appender load is not guarded | exit 1, killed | missing-appender case: the load threw |
| M5 `Add-TcLine` held to ONE open attempt | exit 0, **survived** | nothing, as expected |

4 of 5 killed. M5 survived because appenders that all open with a shared ReadWrite never refuse each other,
so the concurrency case proves the shared open and not the retry. `lib\append-line.ps1`'s own self-test covers
the retry against a handle that denies writers.

## Other files several processes append to

A sweep of every append in the tree. It REPORTS and fixes nothing. "Read" means I opened the writer and the
concurrent launch myself. "Sweep" means a read-only search agent reported it and I did not re-open it.

**Concurrent writers, shown:**

| file | writer | on failure | evidence |
|---|---|---|---|
| `grocery\alert-log.txt` | `grocery\send-alert.ps1:85-89` `Log()`, a bare `Add-Content`, 5 tries 120 ms apart | after 5 tries the line goes to `Write-Host` only, and callers pipe the child's output away | Read. `send-alert.ps1:748-756` says so itself: `fanout-lib.ps1` runs advisory audits side by side, and three of them page on their own as grandchildren. The retry is not measured. A bare `Add-Content` with no retry landed 5 of 1,200. |
| `grocery\out\capture-cursor-log.jsonl` | `grocery\capture-policy-lib.ps1:811`, a bare `Add-Content`, no retry | `catch { }`, silent | Read: the append, and `grocery\capture-run.ps1:274-283` starting every headless lane together as `Start-Job` children. `lib\ledger-lock.ps1:13-15` names the Baker's and Family Fare lanes writing the cursor in that same launch. The call sites (`capture-policy-lib.ps1:964,1075`, `pull-regular-familyfare.ps1:1147`) come from the sweep. **The likeliest silent loser of the files that remain.** |
| `<RunDir>\lane-log.jsonl` | `meal-prep\pipeline\hunt-run.ps1:686` `Add-LaneLine`, `[IO.File]::AppendAllText`, 3 tries | throws, the process exits non-zero, and the daemon records a finding | Read: `hunt-daemon.py:683-699` starts one `hunt-run.ps1 -Lane` process per lane line from its async lanes. Loud on failure, so a loss is not silent. |
| `ops\out\events.jsonl` | `lib\event-bus.ps1` | fixed here | above |

**Several writers, overlap possible but not shown (sweep, not re-opened unless marked):**

- `ops\out\gate-readings.jsonl`: `ops\run-gates.ps1:562` `AppendAllText`, one write per run, `catch { }` silent.
  Several `run-gates` share the box (read), but only runs from the SAME checkout share this file.
- `grocery\ad-cycle-log.txt`: one writer, retried, but the capture watchdog opens it `Append`/`None` as a lock
  probe while a capture run may be writing.
- `<RunDir>\density-gaps.jsonl`: `meal-prep\pipeline\map-preresolve.ps1:3424`, a bare `Add-Content`, silent. The
  map lane runs two workers; not confirmed that both hit one RunDir.
- `grocery\notify-log.txt` (`notify-desktop.ps1:95`, 1 retry, then silent), `ops\staged-writes.jsonl` and
  `ops\ghost-journal.jsonl` (`lib\ghost-lib.ps1`, loud), and the capture-run transcript, which starts before
  that run's mutex.
- `grocery\alert-sent-<day>.txt`: written under a mutex, but after a 90 s wait `send-alert.ps1` sends anyway,
  and a failed append there is logged as a failed send although the email went.
- Python appenders (`open(..., 'a')`): recall hook logs, `food-db-conflicts.jsonl`, graph provenance. Python's
  open shares writes on Windows, so they do not refuse each other. They are not the same risk and were not
  measured.

## Appendix: the harness, verbatim

```powershell
# bus-harness.ps1 - drives N concurrent processes through a real Write-TcEvent and writes one row per trial per arm.
# Usage: powershell -NoProfile -File bus-harness.ps1 -Arms old=<lib path>,new=<lib path> -Cells 1,2,4,8 -Events 200 -Trials 5 -RowsOut <jsonl> -Commit <sha>
param(
  # STRINGS, NOT ARRAYS. Under `powershell -File`, `-Cells 1,2,4,8` reaches an [int[]] as the one string "1,2,4,8",
  # and PowerShell's number conversion reads the commas as THOUSANDS SEPARATORS: it bound as 1248 and launched
  # 1,168 child processes on the shared box before it was killed (2026-09-11). Split explicitly, and cap.
  [Parameter(Mandatory=$true)][string]$Arms,     # 'old=<lib>;new=<lib>'
  [string]$Cells = '1;2;4;8',
  [int]$Events = 200,
  [int]$Trials = 5,
  [Parameter(Mandatory=$true)][string]$RowsOut,
  [string]$Commit = '',
  [int]$DeadlineSec = 120
)
$ErrorActionPreference = 'Stop'
if ($Events -lt 2) { throw 'Events must be at least 2: the rendezvous sits between the first and the last write' }
# A NEW VARIABLE: assigning an array back to the [string]-typed $Cells coerces it to "1 2 4 8" again.
$cellList = [int[]]@($Cells -split '[;,\s]+' | Where-Object { $_ } | ForEach-Object { [int]::Parse($_, [Globalization.CultureInfo]::InvariantCulture) })
foreach ($c in $cellList) { if ($c -lt 1 -or $c -gt 16) { throw "Cells: $c writers is outside 1..16 - refusing to launch it on a shared box" } }
Write-Output ('cells resolved: {0}; events per writer {1}; trials {2}' -f ($cellList -join ','), $Events, $Trials)
$PS = (Get-Command powershell).Source
$utf8 = New-Object Text.UTF8Encoding($false)

$child = @'
param([string]$Lib, [string]$Bus, [string]$Root, [string]$Tag, [int]$W, [int]$E, [int]$DeadlineSec)
$ErrorActionPreference = 'Continue'
. $Lib
$ready = [IO.Path]::Combine($Root, 'ready'); $first = [IO.Path]::Combine($Root, 'first')
[IO.File]::WriteAllText([IO.Path]::Combine($ready, $Tag), 'x')
$sw = [Diagnostics.Stopwatch]::StartNew()
while ([IO.Directory]::GetFiles($ready).Length -lt $W -and $sw.Elapsed.TotalSeconds -lt $DeadlineSec) { Start-Sleep -Milliseconds 5 }
$ok = 0; $bad = 0; $threw = 0; $sawAll = 0
$pad = 'x' * 150
for ($i = 0; $i -lt $E; $i++) {
  if ($i -eq ($E - 1)) {
    $sw2 = [Diagnostics.Stopwatch]::StartNew()
    while ([IO.Directory]::GetFiles($first).Length -lt $W -and $sw2.Elapsed.TotalSeconds -lt $DeadlineSec) { Start-Sleep -Milliseconds 5 }
    if ([IO.Directory]::GetFiles($first).Length -ge $W) { $sawAll = 1 }
  }
  try {
    $r = Write-TcEvent -Kind 'measure' -Producer 'scratch\bus-harness.ps1' -Data @{ tag = $Tag; i = $i; pad = $pad } -Path $Bus
    if ($r -eq $true) { $ok++ } else { $bad++ }
  } catch { $threw++ }
  if ($i -eq 0) { [IO.File]::WriteAllText([IO.Path]::Combine($first, $Tag), 'x') }
}
[IO.File]::WriteAllText([IO.Path]::Combine($Root, 'result', $Tag), ('{0} {1} {2} {3}' -f $ok, $bad, $threw, $sawAll))
'@

$base = Join-Path ([IO.Path]::GetTempPath()) ('tc-bush-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
[void][IO.Directory]::CreateDirectory($base)
$childPs1 = Join-Path $base 'child.ps1'
[IO.File]::WriteAllText($childPs1, $child, $utf8)

$armList = @()
foreach ($a in @($Arms -split ';' | Where-Object { $_ })) {
  $name, $lib = $a -split '=', 2
  $md5 = (Get-FileHash -Algorithm MD5 -LiteralPath $lib).Hash.ToLower()
  $armList += [pscustomobject]@{ Name = $name; Lib = $lib; Md5 = $md5 }
}

try {
  foreach ($W in $cellList) {
    for ($t = 1; $t -le $Trials; $t++) {
      # ALTERNATE the arms within each trial, and flip the order every other trial, so load drift is shared.
      $order = if ($t % 2 -eq 1) { $armList } else { @($armList)[($armList.Count - 1)..0] }
      foreach ($arm in $order) {
        $root = Join-Path $base ('{0}-w{1}-t{2}' -f $arm.Name, $W, $t)
        foreach ($sub in 'ready', 'first', 'result', 'log') { [void][IO.Directory]::CreateDirectory((Join-Path $root $sub)) }
        $bus = Join-Path $root 'bus.jsonl'
        $sw = [Diagnostics.Stopwatch]::StartNew()
        $procs = @()
        foreach ($k in 1..$W) {
          $tag = 'c' + $k
          $p = Start-Process -FilePath $PS -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"' + $childPs1 + '"'),
            '-Lib', ('"' + $arm.Lib + '"'), '-Bus', ('"' + $bus + '"'), '-Root', ('"' + $root + '"'), '-Tag', $tag, '-W', $W, '-E', $Events, '-DeadlineSec', $DeadlineSec) `
            -PassThru -NoNewWindow -RedirectStandardOutput (Join-Path $root "log\$tag.out") -RedirectStandardError (Join-Path $root "log\$tag.err")
          $null = $p.Handle
          $procs += $p
        }
        foreach ($p in $procs) { [void]$p.WaitForExit(600000) }   # hang guard, not a bar
        $elapsed = $sw.ElapsedMilliseconds

        $retTrue = 0; $retFalse = 0; $threw = 0; $reported = 0; $sawAll = 0
        foreach ($f in [IO.Directory]::GetFiles((Join-Path $root 'result'))) {
          $parts = ([IO.File]::ReadAllText($f)).Trim() -split ' '
          if ($parts.Count -ne 4) { continue }
          $reported++
          $retTrue += [int]$parts[0]; $retFalse += [int]$parts[1]; $threw += [int]$parts[2]; $sawAll += [int]$parts[3]
        }
        $lines = @(); if (Test-Path -LiteralPath $bus) { $lines = [IO.File]::ReadAllLines($bus) }
        $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
        $unparse = 0; $dups = 0; $otherKind = 0
        foreach ($ln in $lines) {
          if (-not $ln.Trim()) { continue }
          try { $row = $ln | ConvertFrom-Json } catch { $unparse++; continue }
          if ([string]$row.kind -ne 'measure') { $otherKind++; continue }
          if (-not $seen.Add(([string]$row.tag) + '|' + ([string]$row.i))) { $dups++ }
        }
        $sent = $W * $Events
        $landed = $seen.Count
        $overlap = if ($W -ge 2) { ($sawAll -eq $W) } else { $null }
        $valid = ($reported -eq $W) -and ($W -eq 1 -or $sawAll -eq $W)
        $row = [ordered]@{
          arm = $arm.Name; writers = $W; trial = $t; events_per_writer = $Events
          sent = $sent; landed = $landed; lost = ($sent - $landed); lines = $lines.Count
          unparseable = $unparse; duplicates = $dups; other_kind = $otherKind
          returned_true = $retTrue; returned_false = $retFalse; threw = $threw
          children_reported = $reported; saw_all_first_writes = $sawAll; overlap_proven = $overlap; valid = $valid
          boolean_honest = ($retTrue -eq $landed)
          elapsed_ms_info = $elapsed
          lib = $arm.Lib; lib_md5 = $arm.Md5; base_commit = $Commit; harness = 'scratch bus-harness.ps1 (recorded in the MEASURE doc)'
        }
        [IO.File]::AppendAllText($RowsOut, (($row | ConvertTo-Json -Compress) + "`n"), $utf8)
        Write-Output ('{0,-4} W={1} t={2}: landed {3} of {4} (lost {5}), $true {6}, $false {7}, threw {8}, reported {9} of {1}, saw all first writes {10} of {1}, valid={11}, {12} ms' -f `
          $arm.Name, $W, $t, $landed, $sent, ($sent - $landed), $retTrue, $retFalse, $threw, $reported, $sawAll, $valid, $elapsed)
        Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
      }
    }
  }
} finally {
  Remove-Item -LiteralPath $base -Recurse -Force -ErrorAction SilentlyContinue
}
Write-Output 'BUS-HARNESS-COMPLETE'
```
