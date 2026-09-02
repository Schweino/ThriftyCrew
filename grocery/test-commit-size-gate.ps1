<#
  test-commit-size-gate.ps1 - capture-run's daily commit refuses a commit that is not a day of prices.

  WHY (2026-08-22/23). $inputPaths stages 'grocery/out' as a WHOLE DIRECTORY, so .gitignore is the only
  thing between a new subdirectory and the repo - and .gitignore is an exclusion list, which means
  anything new is tracked BY DEFAULT. When the browser driver started writing persistent Chrome profiles
  under out\, d2a864c0 committed 4,388 files / 797,640 insertions in one go and nobody noticed for two
  days. It became HALF the pack - 191 MB of ~380 MB - and the contents were the seeded store sessions,
  i.e. cookies, on a remote.

  A sweep cannot be made safe by listing what to exclude, because the next tool to write under out\ has
  not been written yet. So the gate COUNTS instead, and this file proves it counts right.

  IT RUNS THE SHIPPED BLOCK, NEVER A COPY. The gate is extracted out of capture-run.ps1 by marker and
  executed against a THROWAWAY git repo in %TEMP% - never this one. A transcribed copy would pass forever
  while production drifted, which is the same reason test-cadence.ps1 pulls its helpers out of
  check-ad-cycles rather than restating them.

  Run:  powershell -NoProfile -File grocery	est-commit-size-gate.ps1
  Exit: 0 pass, 1 a case failed, 3 could not find the gate (BLIND - nothing was proven).
#>
$ErrorActionPreference='Continue'
$d = Join-Path $env:TEMP ('gate-' + [guid]::NewGuid().ToString('N').Substring(0,8))
New-Item -ItemType Directory $d -Force | Out-Null
Push-Location $d
try {
  & git init -q .; & git config user.email t@t; & git config user.name t
  New-Item -ItemType Directory (Join-Path $d 'grocery\out') -Force | Out-Null
  'seed' | Set-Content (Join-Path $d 'grocery\out\seed.txt'); & git add -A; & git commit -q -m seed

  # the block under test, lifted verbatim from capture-run.ps1 by marker
  $src = [IO.File]::ReadAllText('C:\Codex\ThriftyCrew\grocery\capture-run.ps1')
  $i = $src.IndexOf('  $newDirs = @()')
  $j = $src.IndexOf('  & git -C $repo diff --cached --quiet', $i)
  if ($i -lt 0 -or $j -lt 0) { Write-Output 'BLIND: could not find the gate markers in capture-run.ps1 - nothing was proven'; exit 3 }
  $gate = $src.Substring($i, $j - $i)
  $repo = $d; $paths = @('grocery/out'); $failed = @(); $ForceBigCommit = $false

  function Try-Gate([int]$n, [int]$kb, [bool]$force) {
    $script:failed = @(); $script:ForceBigCommit = $force
    & git -C $d reset -q --hard | Out-Null
    # reset --hard does NOT remove untracked files; without this each case inherited the last one's 400
    & git -C $d clean -qfd | Out-Null
    $blob = 'x' * ($kb * 1024)
    1..$n | ForEach-Object { $blob | Set-Content (Join-Path $d ("grocery\out\f$_.txt")) }
    & git -C $d add -A -- 'grocery/out' | Out-Null
    $repo = $d; $paths = @('grocery/out'); $failed = @(); $ForceBigCommit = $force
    . ([scriptblock]::Create($gate))
    $stagedAfter = @(& git -C $d diff --cached --name-only | Where-Object { $_ }).Count
    return [pscustomobject]@{ refused = $sizeGateRefused; staged = $stagedAfter; failed = ($failed -join ',') }
  }

  $n=0; $bad=0
  function T($m,$c,$g){ $script:n++; if($c){Write-Output "  ok    $m"} else {$script:bad++; Write-Output "  FAIL  $m -> $g"} }

  $r = Try-Gate 400 1 $false
  T 'MUST FIRE  400 new files is refused, and the index is reset' ($r.refused -and $r.staged -eq 0) ("refused=$($r.refused) staged=$($r.staged)")
  T 'MUST FIRE  the refusal is reported as a failed lane' ($r.failed -match 'commit-size-gate') $r.failed

  $r2 = Try-Gate 12 4 $false
  T 'CLEAN TWIN a normal day (12 files, 48 KB) passes untouched' ((-not $r2.refused) -and $r2.staged -eq 12) ("refused=$($r2.refused) staged=$($r2.staged)")

  $r3 = Try-Gate 40 1024 $false
  T 'MUST FIRE  few files but 40 MB is refused on SIZE, not count' ($r3.refused) ("refused=$($r3.refused)")

  $r4 = Try-Gate 400 1 $true
  T 'CLEAN TWIN -ForceBigCommit lets the same 400 files through' ((-not $r4.refused) -and $r4.staged -eq 400) ("refused=$($r4.refused) staged=$($r4.staged)")

  # THE ACTUAL MECHANISM: a SMALL new directory, well under both caps. This is browser-profiles on the
  # day it arrived, before it grew - the size gate alone would have waved it through.
  #
  # EACH OF THESE TWO GETS ITS OWN REPO. Reusing the one above let a previous case's leftover files
  # reach this one and the clean twin failed for a reason that had nothing to do with what it tests -
  # a fixture whose cases contaminate each other reports the wrong thing twice: once as a false red,
  # and once, later, as a green that was never earned.
  function New-Case([scriptblock]$Setup) {
    $c = Join-Path $env:TEMP ('gatecase-' + [guid]::NewGuid().ToString('N').Substring(0,8))
    New-Item -ItemType Directory $c -Force | Out-Null
    & git -C $c init -q .
    & git -C $c config user.email t@t; & git -C $c config user.name t
    New-Item -ItemType Directory (Join-Path $c 'grocery/out') -Force | Out-Null
    'seed' | Set-Content (Join-Path $c 'grocery/out/seed.txt')
    & git -C $c add -A | Out-Null; & git -C $c commit -q -m seed | Out-Null
    & $Setup $c
    & git -C $c add -A -- 'grocery/out' | Out-Null
    $script:repo = $c; $script:paths = @('grocery/out'); $script:failed = @(); $script:ForceBigCommit = $false
    $repo = $c; $paths = @('grocery/out'); $failed = @(); $ForceBigCommit = $false
    . ([scriptblock]::Create($script:gateSrc))
    $staged = @(& git -C $c diff --cached --name-only | Where-Object { $_ }).Count
    Remove-Item $c -Recurse -Force -ErrorAction SilentlyContinue
    return [pscustomobject]@{ refused = $sizeGateRefused; staged = $staged }
  }
  $script:gateSrc = $gate

  $rNew = New-Case {
    param($c)
    New-Item -ItemType Directory (Join-Path $c 'grocery/out/browser-profiles/fareway') -Force | Out-Null
    1..8 | ForEach-Object { 'cookie' | Set-Content (Join-Path $c ('grocery/out/browser-profiles/fareway/c' + $_ + '.txt')) }
  }
  T 'MUST FIRE  a SMALL never-before-tracked directory is refused (8 files, 0 MB - under both caps)' `
    ($rNew.refused -and $rNew.staged -eq 0) ("refused=$($rNew.refused) staged=$($rNew.staged)")

  # CLEAN TWIN: new files inside an ALREADY-tracked directory are ordinary daily work.
  $rOld = New-Case {
    param($c)
    New-Item -ItemType Directory (Join-Path $c 'grocery/out/regular') -Force | Out-Null
    'd1' | Set-Content (Join-Path $c 'grocery/out/regular/day1.json')
    & git -C $c add -A | Out-Null; & git -C $c commit -q -m 'regular is now tracked' | Out-Null
    'd2' | Set-Content (Join-Path $c 'grocery/out/regular/day2.json')
  }
  T 'CLEAN TWIN a new file in an already-tracked directory is ordinary daily work' `
    (-not $rOld.refused) ("refused=$($rOld.refused)")

  # ---- THE DURABLE WAY THROUGH (2026-08-25) ------------------------------------------------------
  # out\cadence was a real feature that this gate refused correctly on its first morning and then went
  # on refusing, because the only exits it named were .gitignore (wrong - the stamps belong in git) and
  # -ForceBigCommit (impossible - Task Scheduler passes no switches). Both scheduled runs failed every
  # morning and the board stopped shipping. out-declared-families.json is the exit an unattended run
  # can take; these two cases prove it admits ONLY what is declared, and admits nothing when it breaks.
  $rDecl = New-Case {
    param($c)
    New-Item -ItemType Directory (Join-Path $c 'grocery/out/cadence') -Force | Out-Null
    1..10 | ForEach-Object { '2026-08-24T08:19:48.7480420-05:00' | Set-Content (Join-Path $c ('grocery/out/cadence/cadence-a' + $_ + '.txt')) }
    New-Item -ItemType Directory (Join-Path $c 'grocery') -Force | Out-Null
    '{ "families": [ { "dir": "cadence", "since": "2026-08-24", "writer": "grocery/check-ad-cycles.ps1", "why": "auditor stamps" } ] }' |
      Set-Content (Join-Path $c 'grocery/out-declared-families.json') -Encoding UTF8
  }
  T 'CLEAN TWIN a DECLARED new directory is admitted (this is the 08-24 cadence outage)' `
    ((-not $rDecl.refused) -and $rDecl.staged -gt 0) ("refused=$($rDecl.refused) staged=$($rDecl.staged)")

  # A manifest that cannot be parsed must not become a skeleton key. Truncated JSON is the realistic
  # shape - a half-written file from an interrupted edit - and the safe reading of it is "declares
  # nothing", never "declares everything".
  $rBad = New-Case {
    param($c)
    New-Item -ItemType Directory (Join-Path $c 'grocery/out/cadence') -Force | Out-Null
    1..10 | ForEach-Object { 'stamp' | Set-Content (Join-Path $c ('grocery/out/cadence/cadence-a' + $_ + '.txt')) }
    '{ "families": [ { "dir": "caden' | Set-Content (Join-Path $c 'grocery/out-declared-families.json') -Encoding UTF8
  }
  T 'MUST FIRE  an UNPARSEABLE manifest declares nothing and the new directory still refuses' `
    ($rBad.refused -and $rBad.staged -eq 0) ("refused=$($rBad.refused) staged=$($rBad.staged)")

  # And the undeclared directory in the SAME repo as a valid manifest still refuses - the list admits
  # by name, not by existing.
  $rOther = New-Case {
    param($c)
    New-Item -ItemType Directory (Join-Path $c 'grocery/out/browser-profiles/sams') -Force | Out-Null
    1..8 | ForEach-Object { 'cookie' | Set-Content (Join-Path $c ('grocery/out/browser-profiles/sams/c' + $_ + '.txt')) }
    '{ "families": [ { "dir": "cadence", "since": "2026-08-24", "writer": "x", "why": "y" } ] }' |
      Set-Content (Join-Path $c 'grocery/out-declared-families.json') -Encoding UTF8
  }
  T 'MUST FIRE  a valid manifest does not admit a directory it does not name' `
    ($rOther.refused -and $rOther.staged -eq 0) ("refused=$($rOther.refused) staged=$($rOther.staged)")

  # ---- SERVED-DIRTY: WHAT THE CHAIN WROTE vs WHAT IT STAGED (2026-09-02, queue 2026-09-02-reanch1) ----
  # Same harness, second shipped block. On 2026-09-02 the chain re-anchored 584 authored specs and rebuilt
  # three data files and three tool pages AFTER guards passed, and $servedPaths listed none of them, so 536
  # rewritten files sat dirty on a shared tree and were swept by hand in an unlabelled commit. The paths are
  # in the list now; this block is what notices the NEXT writer to join the chain. Lifted by marker and run
  # against a throwaway repo, never this one - a transcribed copy would pass forever while production drifted.
  $si = $src.IndexOf('# >>> SERVED-DIRTY BLOCK')
  $sj = $src.IndexOf('# <<< SERVED-DIRTY BLOCK', [Math]::Max($si, 0))
  if ($si -lt 0 -or $sj -lt 0) { Write-Output 'BLIND: could not find the served-dirty markers in capture-run.ps1 - nothing was proven'; exit 3 }
  $srv = $src.Substring($si, $sj - $si)
  # A STUB, SO THE ALERT PATH IS ACTUALLY EXERCISED. Without it the block's Send-Alert throws
  # CommandNotFound into its own catch and the alert BODY - which interpolates $servedDirty and $today -
  # would never be composed, so a typo in it would ship unproven.
  function Send-Alert { param($Subject, $Body) $script:alertSubject = $Subject; $script:alertBody = $Body }
  function Run-Served([bool]$ship, [scriptblock]$Setup) {
    $c = Join-Path $env:TEMP ('served-' + [guid]::NewGuid().ToString('N').Substring(0,8))
    New-Item -ItemType Directory $c -Force | Out-Null
    & git -C $c init -q .
    & git -C $c config user.email t@t; & git -C $c config user.name t
    New-Item -ItemType Directory (Join-Path $c 'meal-prep/db/recipes') -Force | Out-Null
    New-Item -ItemType Directory (Join-Path $c 'public') -Force | Out-Null
    '{"slug":"x","cost_ps":1.23}' | Set-Content (Join-Path $c 'meal-prep/db/recipes/x.json')
    'board' | Set-Content (Join-Path $c 'public/board.json')
    & git -C $c add -A | Out-Null; & git -C $c commit -q -m seed | Out-Null
    & $Setup $c
    # the four variables the block reads, exactly as capture-run holds them at that point
    $repo = $c; $today = '2026-09-02'; $shipServed = $ship
    $servedPaths = @('public', 'meal-prep/db/recipes')
    $failed = @()
    $script:alertSubject = ''; $script:alertBody = ''
    # DOT-SOURCE, not &: the block's `$failed += ...` must land in THIS scope or the assertion below
    # would read an unmodified copy and pass on a block that reported nothing.
    $out = . ([scriptblock]::Create($srv))
    Remove-Item $c -Recurse -Force -ErrorAction SilentlyContinue
    return [pscustomobject]@{ failed = ($failed -join ','); text = ((@($out) | ForEach-Object { [string]$_ }) -join "`n"); subject = $script:alertSubject; body = $script:alertBody }
  }

  # MUST-FIRE, built from the real 2026-09-02 shape: the chain rewrote a tracked spec and committed without it.
  $sDirty = Run-Served $true { param($c) '{"slug":"x","cost_ps":2.34}' | Set-Content (Join-Path $c 'meal-prep/db/recipes/x.json') }
  T 'MUST FIRE  a tracked served file left dirty after the commit is reported and fails the lane' `
    (($sDirty.failed -match 'served-dirty') -and ($sDirty.text -match 'served-dirty: 1 tracked served file')) ("failed=$($sDirty.failed) text=$($sDirty.text)")
  T 'MUST FIRE  and the alert body composes (it interpolates the count, the paths and the date)' `
    (($sDirty.subject -match '2026-09-02') -and ($sDirty.body -match 'meal-prep/db/recipes/x.json')) ("subject=$($sDirty.subject)")

  # CLEAN TWIN: the same repo with nothing left behind. Silent, and the lane is untouched.
  $sClean = Run-Served $true { param($c) }
  T 'CLEAN TWIN a clean tree after the commit stays silent and does not fail the lane' `
    (($sClean.failed -eq '') -and ($sClean.text -match 'served-dirty: none')) ("failed=$($sClean.failed) text=$($sClean.text)")

  # CLEAN TWIN: guards blocked, so the chain deliberately staged INPUTS only. Dirty served files are the
  # expected state there and must not page - or the block would cry wolf on every genuinely blocked board.
  $sBlocked = Run-Served $false { param($c) '{"slug":"x","cost_ps":2.34}' | Set-Content (Join-Path $c 'meal-prep/db/recipes/x.json') }
  T 'CLEAN TWIN a guards-blocked run (shipServed false) does not report served files as dirty' `
    (($sBlocked.failed -eq '') -and ($sBlocked.text -eq '')) ("failed=$($sBlocked.failed) text=$($sBlocked.text)")

  Write-Output ''
  Write-Output ("SELFTEST: {0}/{1} pass" -f ($n-$bad), $n)
  Write-Output ("COMMIT-SIZE-GATE-COMPLETE cases={0} failed={1}" -f $n, $bad)
  if ($bad) { exit 1 }
} finally { Pop-Location; Remove-Item $d -Recurse -Force -ErrorAction SilentlyContinue }
