# PLAN: a self-test that exits 0 must print its own verdict line

**Status:** PROPOSAL, measured, not built. Brad decides whether run-gates judges this.
**Harness:** a scratch probe reproduced in full at the end of this file. Its discovery is copied from
`ops/run-gates.ps1` at the commit below (same walk, same SKIP list, same `Get-TcSelfTestSwitch` rule), and it
takes its workers from `lib/gate-slots.ps1` like run-gates does.
**Commit it ran at:** `b76db3998`, 2026-09-11, a local commit that was never pushed: `3176eb82b` plus a second keyword
detector, `ops\audit-swallowed-statements.ps1`, which was merged into `ops/audit-keyword-arguments.ps1` the same day and
deleted, and a `pull-grocery-ads.ps1` fix byte-identical to the one on main. That deleted suite is one of the 265
rows: it spells no verdict literal, names two Exit-Guard markers and ends on one, so it is counted in the 67, the
31 and the 20 below. Without it those read 66, 30 and 19, and every other number is unchanged.
**Rows:** `design/selftest-verdict-line-rows-2026-09-11.jsonl`, one row per suite. Every number below is derived
from that file.

## Why

`ops/run-gates.ps1` scores a discovered self-test on its exit code alone (`if ($rc -eq 0) { $pass++ ...`). Twice
now a suite has exited 0 without judging anything:

- `grocery/pull-grocery-ads.ps1` at 8253ded82: the verdict `if` sat on the same line as the last case and was
  parsed as arguments to it. The suite fell into its live pull and exited 0. `ops/audit-keyword-arguments.ps1`
  now blocks that exact shape.
- `grocery/aisle-test.ps1`, recorded in `lib/guard-contract.ps1`'s header: a dot-sourced `param()` block reset
  its switch, so `-SelfTest` fell past its 14-case branch to "nothing to judge" and exited 0.

The second shape is not a parse shape, so no source detector catches it. What both cases share is that the
suite's own verdict line never printed. That line is already there in most suites, and nothing reads it.

## Measurement

265 self-tests discovered, 265 run once, 265 exited 0 (none failed, none timed out). The box was saturated by
other sessions' gates, so the probe got one slot and ran at width 1.

| Class | Suites |
|---|---|
| Source spells a verdict literal matching `SELF-?TESTS?:?\s+PASS(ED)?\b` (case-sensitive, read from string tokens, so comments never count) | 198 of 265 |
| ...and some output line CONTAINS that literal's constant head (the text before its first `$` or `{`) | **198 of 198** |
| ...and some output line STARTS with that head | 195 of 198. The 3 others print `GRAPH-GATES SELF-TEST PASS` and similar, name first |
| No such literal | 67 of 265 |
| ...of which the source names an `Exit-Guard`/`Write-GuardComplete` marker | 31, and 20 of those end on that marker |
| ...of which neither | 36, which print verdicts in other words: `self-test OK`, `all green`, `SELFTEST: 25/25 pass`, `failures: 0` |

A 9-suite overlap is worth naming: they print a `SELF-TEST PASS` line whose literal is computed, not spelled,
so the rule below cannot see a declaration for them.

**Would it have caught the founding case?** Yes, and only in the strict form. At 8253ded82 the only verdict
literal in `pull-grocery-ads.ps1` is `SELF-TEST PASS: $n case(s)` on the self-test line, and its live path
prints `PASS` as a store status. So "any PASS word in the output" would have scored the fall-through green,
while "the declared head `SELF-TEST PASS:`" would not.

## Proposal, rung 1 (the cheap one)

In run-gates' self-test judging loop, for a suite that exits 0:

1. Read the suite's string tokens (the file is already read for discovery) and keep literals matching
   `SELF-?TESTS?:?\s+PASS(ED)?\b`, case-sensitive. Take each one's head up to the first `$` or `{`, trimmed,
   and keep heads of 6 characters or more.
2. If there are none, judge as today.
3. If there are some and no stdout line CONTAINS any of them, score the suite FAIL with
   `exited 0 without printing its own verdict line (<head>)`.

**Acceptance bar, written before building:** 0 new reds over the 265 suites at the commit it lands on, a MUST
FIRE fixture from the 8253ded82 output shape (case lines, no verdict, live-path lines carrying `PASS`), and a
MUST NOT FIRE on a name-first verdict line (`GRAPH-GATES SELF-TEST PASS`).

**When the producer stops.** If the token read broke, every suite would declare nothing and the rule would go
quiet while every suite still passed. So it needs a floor in the same change: fewer than 150 declaring suites
(198 today) is could-not-evaluate, exit 3, the same shape as the discovery floor already in that file.

**Known holes, stated rather than hidden:** a case label that quotes the verdict head satisfies it; a suite that
loses its verdict literal along with its verdict line is no longer judged; the 67 suites without a literal are
not covered.

## Rung 2 and beyond, not proposed yet

- The 31 marker-naming suites: "the output ends on the named marker" would be red on 11 of them today, because
  their marker belongs to the live path and their self-test prints a tally instead. A marker whose name carries
  `SELFTEST` is the better declaration, and it is unmeasured.
- The 36 with neither could adopt `SELF-TEST PASS:` wording one at a time. A sweep is not asked for.

## Harness

Run as `powershell -NoProfile -File <probe> -Root <checkout> -OutJsonl <rows> -Want 10`. The rows it writes
carry each suite's full stdout (528,577 bytes here). The committed rows file is the derived per-suite
classification, without the outputs.

```powershell
param([string]$Root, [string]$OutJsonl, [int]$Want = 10)
$ErrorActionPreference = 'Stop'
. (Join-Path $Root 'lib\git-repo-env.ps1'); Clear-TcGitRepoEnv
. (Join-Path $Root 'lib\selftest-discovery.ps1')
. (Join-Path $Root 'lib\tree-walk.ps1')
. (Join-Path $Root 'lib\gate-slots.ps1')
. (Join-Path $Root 'lib\parallel-run.ps1')
$SKIP = @('check-ad-cycles.ps1', 'test-auditors.ps1')
$rootFull = Get-TcRootFull $Root
$scripts = @(Get-ChildItem $rootFull -Recurse -File -Filter *.ps1 -ErrorAction SilentlyContinue |
  Where-Object { (Get-TcPathBelowRoot $_.FullName $rootFull) -notmatch '\\worktrees\\|\\archive\\|node_modules|\.venv|\\out\\' } | Sort-Object FullName)
$suites = New-Object System.Collections.ArrayList
foreach ($s in $scripts) {
  if ($SKIP -contains $s.Name) { continue }
  if ($s.Name -eq 'run-gates.ps1' -and $s.DirectoryName -like '*\ops') { continue }
  $t = [IO.File]::ReadAllText($s.FullName)
  $found = Get-TcSelfTestSwitch -Text $t
  if (-not $found.Switch) { continue }
  $tok = $null; $err = $null
  [void][System.Management.Automation.Language.Parser]::ParseInput($t, [ref]$tok, [ref]$err)
  $lits = @($tok | Where-Object { $_.Kind -in @('StringLiteral','StringExpandable','HereStringLiteral','HereStringExpandable') -and ([string]$_.Value) -cmatch '\bPASS(ED)?\b' } | ForEach-Object { [string]$_.Value })
  [void]$suites.Add([pscustomobject]@{ File = $s.FullName; Rel = (Get-TcPathBelowRoot $s.FullName $rootFull).TrimStart('\'); Switch = $found.Switch; Lits = $lits })
}
$PSEXE = (Get-Command powershell).Source
$jobs = @($suites | ForEach-Object { [pscustomobject]@{ Exe = $PSEXE; ArgList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $_.File, ('-' + $_.Switch)) } })
$lease = Enter-TcGateSlots -Want $Want -OnWait { Write-Output 'waiting for a gate slot' }
if ($lease.TimedOut) { 'no gate slot'; exit 3 }
try { $res = Invoke-TcParallel -Jobs $jobs -Concurrency $lease.Count -WorkingDirectory $Root } finally { Exit-TcGateSlots $lease }
$sb = New-Object Text.StringBuilder
for ($i = 0; $i -lt $suites.Count; $i++) {
  $row = [ordered]@{ rel = $suites[$i].Rel; switch = $suites[$i].Switch; exit = $res[$i].ExitCode; ms = [int]$res[$i].Ms
                     timedOut = [bool]$res[$i].TimedOut; lits = @($suites[$i].Lits); out = @($res[$i].Out) }
  [void]$sb.Append((ConvertTo-Json -InputObject $row -Compress -Depth 4)).Append("`n")
}
[IO.File]::WriteAllText($OutJsonl, $sb.ToString(), (New-Object Text.UTF8Encoding($false)))
```

The classification then reads each row: `declares` is a literal matching the tally pattern, the head is cut at
the first `$` or `{` and kept at 6 characters or more, and `printed` is any stdout line containing a head
(ordinal substring). The line-start variant and the marker counts use the same rows.
