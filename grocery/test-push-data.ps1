<#
  test-push-data.ps1 - push-data.ps1's commit lane stages what the pipeline owns, and nothing else.

  WHY (2026-09-05/06, PLAN-top5-2026-09-06 area 3). push-data.ps1 was invoked twice, a minute apart, and
  its `git add -A` committed AND PUSHED 325 files to main - 192 of them .ps1 files MID-EDIT, 27 of which
  threw at startup - because it was written in July for a tree that held only raw store inputs and nothing
  re-checked that assumption when agents began editing code in the same tree. Two more defects rode along:
  the commit's exit code was thrown away (so a hook refusal was invisible and the run pushed anyway and
  reported success), and a `git checkout --` over five files silently DISCARDED local edits.

  IT RUNS THE SHIPPED BLOCK, NEVER A COPY. The commit lane is extracted out of push-data.ps1 by marker and
  executed against THROWAWAY git repos in %TEMP%, each with its own bare remote - never this one. A
  transcribed copy would pass forever while production drifted, which is the rule test-commit-size-gate
  already sets for capture-run's gate.

  Run:  powershell -NoProfile -File grocery\test-push-data.ps1
  Exit: 0 pass, 1 a case failed, 3 could not find the lane (BLIND - nothing was proven).
#>
param([switch]$SelfTest)   # accepted so ops\run-gates.ps1 discovers this file; the cases run either way
$ErrorActionPreference = 'Continue'
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'lib\bot-paths.ps1')

$src = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'push-data.ps1'))
$i = $src.IndexOf('# >>> PUSH-DATA COMMIT LANE')
$j = $src.IndexOf('# <<< PUSH-DATA COMMIT LANE', [Math]::Max($i, 0))
if ($i -lt 0 -or $j -le $i) {
  Write-Output 'BLIND: could not find the commit-lane markers in push-data.ps1 - nothing was proven'
  exit 3
}
$lane = $src.Substring($i, $j - $i)

$n = 0; $bad = 0
function T([string]$m, [bool]$c, [string]$g) {
  $script:n++
  if ($c) { Write-Output "  ok    $m" } else { $script:bad++; Write-Output "  FAIL  $m -> $g" }
}

$made = New-Object System.Collections.ArrayList
function New-Repo {
  <# A work repo with a BARE remote, so "did it push?" is a fact about a remote ref rather than an
     inference from an exit code. The seed commit gives HEAD something to read-tree from. #>
  $id   = [guid]::NewGuid().ToString('N').Substring(0, 8)
  $bare = Join-Path $env:TEMP ("pd-remote-$id")
  $work = Join-Path $env:TEMP ("pd-work-$id")
  [void]$made.Add($bare); [void]$made.Add($work)
  & git init -q --bare $bare
  New-Item -ItemType Directory -Force $work | Out-Null
  & git -C $work init -q -b main .
  & git -C $work config user.email t@t
  & git -C $work config user.name  Session
  & git -C $work config commit.gpgsign false
  foreach ($d in @('grocery/out/regular', 'public', 'meal-prep/db/recipes', 'design')) {
    New-Item -ItemType Directory -Force (Join-Path $work $d) | Out-Null
  }
  'seed'                | Set-Content (Join-Path $work 'grocery/out/regular/day1.json')
  'ph'                  | Set-Content (Join-Path $work 'grocery/price-history.json')
  'board'               | Set-Content (Join-Path $work 'public/board.json')
  '{"slug":"x"}'        | Set-Content (Join-Path $work 'meal-prep/db/recipes/x.json')
  '# a script'          | Set-Content (Join-Path $work 'grocery/push-data.ps1')
  'notes'               | Set-Content (Join-Path $work 'design/PLAN-x.md')
  & git -C $work add -A | Out-Null
  & git -C $work commit -q -m seed | Out-Null
  & git -C $work remote add origin $bare
  & git -C $work push -q origin main
  return [pscustomobject]@{ Work = $work; Bare = $bare }
}

function Invoke-Lane {
  <# Drives the SHIPPED block. $Setup dirties the fixture; the block then does the whole staging, private
     index, commit, rebase, push and leftover report. Dot-sourced so `$committed` and friends land here. #>
  param([scriptblock]$Setup, [bool]$ShipServed = $true, [string]$HookBody = $null)
  $r = New-Repo
  if ($HookBody) {
    $hookDir = Join-Path $r.Work '.git\hooks'
    New-Item -ItemType Directory -Force $hookDir | Out-Null
    [IO.File]::WriteAllText((Join-Path $hookDir 'pre-commit'), ($HookBody -replace "`r`n", "`n"), (New-Object Text.UTF8Encoding($false)))
  }
  & $Setup $r.Work
  $repo        = $r.Work
  $inputPaths  = Get-BotInputPaths
  $servedPaths = Get-BotServedPaths
  $shipServed  = $ShipServed
  $commitMsg   = 'Local browser-store refresh 2026-09-06 09:00'
  $BotName     = 'smp-pipeline-bot'
  $BotEmail    = 'actions@users.noreply.github.com'
  $verdictWhy  = 'fixture'
  $staged = @(); $committed = $false; $commitRefused = $false; $pushed = $false; $leftoverDirty = @()
  $text = (. ([scriptblock]::Create($lane))) | ForEach-Object { [string]$_ }
  # WHAT LANDED, read out of GIT rather than out of the block's own variables - a block that lies about
  # what it staged would otherwise be believed by the assertion that reads its own report.
  $inCommit = @(& git -C $r.Work show --name-only --pretty=format: HEAD | Where-Object { $_ })
  $remoteHead = (@(& git -C $r.Bare rev-parse main 2>$null) -join '').Trim()
  $localHead  = (@(& git -C $r.Work rev-parse HEAD) -join '').Trim()
  $stillStaged = @(& git -C $r.Work diff --cached --name-only | Where-Object { $_ })
  return [pscustomobject]@{
    Work = $r.Work; Bare = $r.Bare
    Committed = $committed; Refused = $commitRefused; Pushed = $pushed
    Staged = $staged; Leftover = $leftoverDirty
    InCommit = $inCommit; RemoteHead = $remoteHead; LocalHead = $localHead; StillStaged = $stillStaged
    Text = (@($text) -join "`n")
  }
}

try {
  # ---- 1. OWNERSHIP STAGING: the 2026-09-05 shape, a .ps1 dirty beside a day of prices --------------
  $r1 = Invoke-Lane {
    param($w)
    'day2'        | Set-Content (Join-Path $w 'grocery/out/regular/day2.json')
    '# EDITED, MID-EDIT, BY A SESSION' | Set-Content (Join-Path $w 'grocery/push-data.ps1')
    'edited plan' | Set-Content (Join-Path $w 'design/PLAN-x.md')
  }
  T 'MUST FIRE  a session .ps1 dirty in the tree is NOT in the bot commit (this is 3c44d0c1, 192 files)' `
    ($r1.InCommit -notcontains 'grocery/push-data.ps1' -and $r1.InCommit -notcontains 'design/PLAN-x.md') `
    ("inCommit=" + ($r1.InCommit -join ','))
  T 'CLEAN TWIN the owned data file IS in the bot commit (the run still ships prices)' `
    ($r1.InCommit -contains 'grocery/out/regular/day2.json') ("inCommit=" + ($r1.InCommit -join ','))
  T 'MUST FIRE  the unowned dirty paths are REPORTED by name, not silently dropped' `
    (($r1.Leftover -contains 'grocery/push-data.ps1') -and ($r1.Leftover -contains 'design/PLAN-x.md')) `
    ("leftover=" + ($r1.Leftover -join ','))
  T 'CLEAN TWIN the session .ps1 still holds the session''s edit afterwards (nothing was discarded)' `
    ((Get-Content (Join-Path $r1.Work 'grocery/push-data.ps1') -Raw) -match 'MID-EDIT') 'the file was rewritten'

  # CLEAN TWIN: only owned files dirty -> every one of them is in the commit.
  $r2 = Invoke-Lane {
    param($w)
    'day2' | Set-Content (Join-Path $w 'grocery/out/regular/day2.json')
    'ph2'  | Set-Content (Join-Path $w 'grocery/price-history.json')
  }
  T 'CLEAN TWIN with only owned files dirty, the commit contains all of them and nothing else' `
    ($r2.Committed -and ($r2.InCommit.Count -eq 2) -and ($r2.InCommit -contains 'grocery/price-history.json')) `
    ("committed=$($r2.Committed) inCommit=" + ($r2.InCommit -join ','))

  # ---- 2. THE COMMIT'S EXIT CODE (defect 2) ----------------------------------------------------------
  # The pre-commit hook installed on 2026-09-05 can refuse a commit. The old script piped the commit to
  # Out-Null and pushed regardless, printing "raw store inputs pushed".
  $r3 = Invoke-Lane -HookBody "#!/usr/bin/env sh`nexit 1`n" -Setup {
    param($w) 'day2' | Set-Content (Join-Path $w 'grocery/out/regular/day2.json')
  }
  T 'MUST FIRE  a hook that REFUSES the commit is noticed (the run says COMMIT REFUSED)' `
    ($r3.Refused -and ($r3.Text -match 'COMMIT REFUSED')) ("refused=$($r3.Refused) text=$($r3.Text)")
  T 'MUST FIRE  and NOTHING is pushed - the remote ref is exactly where it was' `
    ((-not $r3.Pushed) -and ($r3.RemoteHead -eq $r3.LocalHead)) `
    ("pushed=$($r3.Pushed) remote=$($r3.RemoteHead) local=$($r3.LocalHead)")

  $r4 = Invoke-Lane -HookBody "#!/usr/bin/env sh`nexit 0`n" -Setup {
    param($w) 'day2' | Set-Content (Join-Path $w 'grocery/out/regular/day2.json')
  }
  T 'CLEAN TWIN a hook that PASSES lets the commit and the push through' `
    ($r4.Committed -and $r4.Pushed -and ($r4.RemoteHead -eq $r4.LocalHead) -and $r4.InCommit.Count -eq 1) `
    ("committed=$($r4.Committed) pushed=$($r4.Pushed) remote=$($r4.RemoteHead) local=$($r4.LocalHead)")

  # ---- 3. THE DISCARD IS GONE (defect 3) -------------------------------------------------------------
  # `git checkout -- grocery/price-history.json ...` ran FIRST, every time, and threw away whatever local
  # edit was there. That is data loss, and it was silent.
  $r5 = Invoke-Lane {
    param($w) 'LOCAL EDIT THAT MUST SURVIVE' | Set-Content (Join-Path $w 'grocery/price-history.json')
  }
  T 'MUST FIRE  a local edit to a cloud-owned file SURVIVES the run (it is committed, never discarded)' `
    (((Get-Content (Join-Path $r5.Work 'grocery/price-history.json') -Raw) -match 'MUST SURVIVE') -and
     ($r5.InCommit -contains 'grocery/price-history.json')) `
    ("inCommit=" + ($r5.InCommit -join ','))
  # CLEAN TWIN: a CLEAN cloud-owned file is untouched - no empty commit, no rewrite.
  $r6 = Invoke-Lane { param($w) }
  T 'CLEAN TWIN a tree with nothing dirty commits nothing and says so' `
    ((-not $r6.Committed) -and (-not $r6.Refused) -and ($r6.Text -match 'no pipeline-owned changes')) `
    ("committed=$($r6.Committed) text=$($r6.Text)")

  # ---- 4. THE PRIVATE INDEX (the 2026-08-25 shape, 0c47012c) -----------------------------------------
  # `git commit` with no pathspec commits the whole INDEX, so explicit staging alone does not stop a bot
  # from shipping what a session left staged.
  $r7 = Invoke-Lane {
    param($w)
    'day2'                | Set-Content (Join-Path $w 'grocery/out/regular/day2.json')
    'A SESSION STAGED ME' | Set-Content (Join-Path $w 'design/PLAN-x.md')
    & git -C $w add -- 'design/PLAN-x.md' | Out-Null
  }
  T 'MUST FIRE  a file a SESSION left staged is NOT in the bot commit (the private index)' `
    ($r7.InCommit -notcontains 'design/PLAN-x.md') ("inCommit=" + ($r7.InCommit -join ','))
  T 'MUST FIRE  and that file is STILL STAGED afterwards - the session''s index was not disturbed' `
    ($r7.StillStaged -contains 'design/PLAN-x.md') ("stillStaged=" + ($r7.StillStaged -join ','))
  T 'CLEAN TWIN the bot commit is exactly its own owned set' `
    (($r7.InCommit.Count -eq 1) -and ($r7.InCommit -contains 'grocery/out/regular/day2.json')) `
    ("inCommit=" + ($r7.InCommit -join ','))
  # AND THE INDEX IS BACK IN STEP FOR WHAT WAS COMMITTED. A private-index commit moves HEAD while the real
  # index still holds the old blobs, which would show the just-committed file as a staged REVERT.
  T 'CLEAN TWIN the committed path is NOT left staged as a revert against the new HEAD' `
    ($r7.StillStaged -notcontains 'grocery/out/regular/day2.json') ("stillStaged=" + ($r7.StillStaged -join ','))

  # ---- 4b. THE REBASE ONLY RUNS WHEN THE REMOTE ACTUALLY MOVED ---------------------------------------
  # `rebase.autoStash` restores WIP with `stash apply`, which does NOT restore the INDEX - so a rebase on
  # every run would unstage a session's deliberately staged file even though the bot commit never touched
  # it. The ordinary run needs no rebase at all. This case proves the rebase still WORKS when it is really
  # needed, so skipping it in the common path did not quietly disable the divergence handling.
  $rDiv = Invoke-Lane {
    param($w)
    'from another machine' | Set-Content (Join-Path $w 'grocery/out/regular/remote.json')
    & git -C $w add -A -- 'grocery/out/regular/remote.json' | Out-Null
    & git -C $w -c user.name=Other -c user.email=o@o commit -q -m 'another machine pushed' | Out-Null
    & git -C $w push -q origin main | Out-Null
    & git -C $w reset -q --hard HEAD~1 | Out-Null
    'day2' | Set-Content (Join-Path $w 'grocery/out/regular/day2.json')
  }
  T 'CLEAN TWIN a diverged remote is rebased onto and the push still lands' `
    ($rDiv.Committed -and $rDiv.Pushed -and ($rDiv.Text -match 'origin/main moved') -and ($rDiv.RemoteHead -eq $rDiv.LocalHead)) `
    ("committed=$($rDiv.Committed) pushed=$($rDiv.Pushed) remote=$($rDiv.RemoteHead) local=$($rDiv.LocalHead)")
  T 'CLEAN TWIN and the other machine''s commit survived the rebase' `
    ((Test-Path (Join-Path $rDiv.Work 'grocery/out/regular/remote.json'))) 'the other machine''s file is gone'

  # ---- 5. SERVED FILES ARE GATED ON THE GUARD VERDICT ------------------------------------------------
  # export-feed writes public\smp-feed.json BEFORE guards run and every recipe card prices off that feed,
  # so a board the gate rejected must not reach the edge through this door either.
  $r8 = Invoke-Lane -ShipServed $false -Setup {
    param($w)
    'day2'  | Set-Content (Join-Path $w 'grocery/out/regular/day2.json')
    'newer' | Set-Content (Join-Path $w 'public/board.json')
  }
  T 'MUST FIRE  with no green verdict, public\** is NOT staged and the run says so' `
    (($r8.InCommit -notcontains 'public/board.json') -and ($r8.InCommit -contains 'grocery/out/regular/day2.json') -and
     ($r8.Text -match 'staging INPUTS only')) ("inCommit=" + ($r8.InCommit -join ',') + " text=" + $r8.Text)
  $r9 = Invoke-Lane -ShipServed $true -Setup {
    param($w)
    'day2'  | Set-Content (Join-Path $w 'grocery/out/regular/day2.json')
    'newer' | Set-Content (Join-Path $w 'public/board.json')
  }
  T 'CLEAN TWIN with a green verdict, public\** ships in the same commit' `
    ($r9.InCommit -contains 'public/board.json') ("inCommit=" + ($r9.InCommit -join ','))

  Write-Output ''
  Write-Output ("SELFTEST: {0}/{1} pass" -f ($n - $bad), $n)
  Write-Output ("PUSH-DATA-LANE-COMPLETE cases={0} failed={1}" -f $n, $bad)
  if ($bad) { exit 1 }
  exit 0
} finally {
  foreach ($d in $made) { Remove-Item -LiteralPath $d -Recurse -Force -ErrorAction SilentlyContinue }
}
